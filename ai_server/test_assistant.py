import asyncio
import base64
import io
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4
from unittest.mock import patch
import httpx
from PIL import Image
from fastapi import FastAPI
from fastapi.testclient import TestClient
from assistant_config import AssistantSettings
from assistant_guard import AssistantGuard, AssistantError
from assistant_models import ChatRequest, FinalAnswer, ToolArguments
from assistant_service import (
    AssistantService,
    GeminiResponses,
    OpenAIResponses,
    TOOLS,
    build_provider,
    gemini_schema,
    prepare_image,
    sanitize_answer,
    strict_answer_schema,
)
import assistant_router
import check_secret_boundary


def request(**kwargs):
    data = {'request_id': str(uuid4()), 'conversation_id': str(uuid4()), 'message': 'Tôi đang đi tới đâu?',
            'context': {'captured_at': datetime.now(timezone.utc).isoformat(), 'status': 'navigating',
                        'route_message': 'Sau 20 mét, rẽ trái', 'position': {'lat': 21, 'lng': 105},
                        'destination': {'lat': 21.001, 'lng': 105.001}, 'accuracy_meters': 5,
                        'gps_updated_at': datetime.now(timezone.utc).isoformat()}}
    data.update(kwargs)
    return ChatRequest.model_validate(data)


def answer(text='Tuyến đi bộ được cập nhật từ GPS.', kind='information'):
    return {'status': 'completed', 'usage': {'input_tokens': 200, 'output_tokens': 40},
            'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': json.dumps({'kind': kind, 'text': text})}]}]}


def call(name, args):
    return {'status': 'completed', 'usage': {'input_tokens': 200, 'output_tokens': 50},
            'output': [{'type': 'function_call', 'name': name, 'call_id': 'call_' + str(uuid4()),
                        'arguments': json.dumps(args)}]}


class FakeProvider:
    def __init__(self, responses=None): self.responses, self.payloads = responses or [answer()], []
    async def create(self, payload):
        self.payloads.append(payload)
        response = self.responses.pop(0)
        if callable(response): return response(payload)
        return response


class Fixture:
    def setup(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = AssistantSettings(api_key='test-key-not-real', signing_secret='x' * 40,
            pairing_code='pairing-test-code', state_path=Path(self.temp.name) / 'limits.sqlite3')
        self.clock = 1000.0
        self.guard = AssistantGuard(self.settings, clock=lambda: self.clock)
    def teardown(self): self.temp.cleanup()


class GuardTests(unittest.TestCase, Fixture):
    def setUp(self): self.setup()
    def tearDown(self): self.teardown()
    def test_pair_auth_expiry_and_revoke(self):
        token = self.guard.pair('pairing-test-code', str(uuid4()), 'test')['access_token']
        client = self.guard.authenticate('Bearer ' + token)
        self.assertTrue(client)
        with self.assertRaises(AssistantError): self.guard.authenticate('Bearer ' + token + 'bad')
        self.guard.revoke(client)
        with self.assertRaises(AssistantError): self.guard.authenticate('Bearer ' + token)
        token = self.guard.pair('pairing-test-code', str(uuid4()), 'test')['access_token']
        self.clock += 86401
        with self.assertRaises(AssistantError): self.guard.authenticate('Bearer ' + token)
    def test_pair_attempts_are_limited_even_when_wrong(self):
        for _ in range(5):
            with self.assertRaises(AssistantError) as error: self.guard.pair('wrong', str(uuid4()), 'test')
            self.assertEqual(error.exception.status, 401)
        with self.assertRaises(AssistantError) as error: self.guard.pair('pairing-test-code', str(uuid4()), 'test')
        self.assertEqual(error.exception.status, 429)
    def test_budget_survives_restart_and_unknown_usage_stays_reserved(self):
        settings = AssistantSettings(api_key='x', signing_secret='x'*40, pairing_code='x'*16,
            daily_usd=.06, device_daily_usd=.06, state_path=self.settings.state_path)
        guard = AssistantGuard(settings, clock=lambda: self.clock)
        turn = guard.reserve('client', str(uuid4()), 'user', None)
        guard.settle(turn, None)
        restarted = AssistantGuard(settings, clock=lambda: self.clock)
        with self.assertRaises(AssistantError) as error: restarted.reserve('another-device', str(uuid4()), 'user', None)
        self.assertEqual(error.exception.code, 'budget_limit')
        self.assertEqual(restarted.usage('client')['spent_usd'], .05)
    def test_duplicate_inflight_and_proactive_cooldown(self):
        request_id = str(uuid4())
        turn = self.guard.reserve('client', request_id, 'proactive', 'error')
        with self.assertRaises(AssistantError) as error: self.guard.reserve('client', request_id, 'user', None)
        self.assertEqual(error.exception.code, 'duplicate_request')
        with self.assertRaises(AssistantError) as error: self.guard.reserve('client', str(uuid4()), 'user', None)
        self.assertEqual(error.exception.code, 'in_progress')
        self.guard.settle(turn, .001)
        with self.assertRaises(AssistantError) as error: self.guard.reserve('client', str(uuid4()), 'proactive', 'poorGps')
        self.assertEqual(error.exception.code, 'proactive_cooldown')
    def test_secret_fields_are_not_represented(self):
        self.assertNotIn('test-key-not-real', repr(self.settings))
        self.assertNotIn('pairing-test-code', repr(self.settings))
    def test_unreadable_assistant_env_fails_closed_without_startup_failure(self):
        with patch('assistant_config.dotenv_values', side_effect=OSError('unreadable')):
            self.assertFalse(AssistantSettings.load().enabled)


class ServiceTests(unittest.IsolatedAsyncioTestCase, Fixture):
    def setUp(self): self.setup()
    def tearDown(self): self.teardown()
    async def test_read_tool_loop_is_bounded_private_and_stateless(self):
        provider = FakeProvider([call('get_journey_status', {}), answer()])
        service = AssistantService(self.settings, self.guard, provider)
        result = await service.chat('client', request())
        self.assertEqual(result['safety'], 'advisory_only')
        self.assertEqual(result['proposals'], [])
        self.assertFalse(provider.payloads[0]['store'])
        self.assertFalse(provider.payloads[0]['parallel_tool_calls'])
        self.assertEqual(provider.payloads[1]['input'][-1]['type'], 'function_call_output')
        self.assertLess(self.guard.usage('client')['spent_usd'], .05)
    async def test_destination_comes_from_search_and_is_only_a_proposal(self):
        async def search(query, lat, lng): return {'lat': 21.1, 'lng': 105.1, 'display_name': 'Công viên được tìm'}
        def propose(payload):
            tool_output = json.loads(payload['input'][-1]['output'])
            return call('propose_navigation_action', {'action': 'set_destination', 'place_id': tool_output['place_id']})
        provider = FakeProvider([call('search_places', {'query': 'công viên'}), propose, answer('Có đề xuất địa điểm, hãy xác nhận trong ứng dụng.')])
        result = await AssistantService(self.settings, self.guard, provider, search).chat('client', request())
        self.assertEqual(result['proposals'][0]['place']['display_name'], 'Công viên được tìm')
        self.assertTrue(result['proposals'][0]['requires_confirmation'])
        result_output = json.loads(provider.payloads[-1]['input'][-1]['output'])
        self.assertFalse(result_output['executed'])
    async def test_fabricated_destination_and_proactive_mutation_are_rejected(self):
        proposal = call('propose_navigation_action', {'action': 'set_destination', 'place_id': 'made-up'})
        provider = FakeProvider([proposal, answer()])
        service = AssistantService(self.settings, self.guard, provider)
        result = await service.chat('client', request())
        self.assertEqual(result['proposals'], [])
        provider = FakeProvider([call('propose_navigation_action', {'action': 'cancel_navigation', 'place_id': None}), answer()])
        service = AssistantService(self.settings, self.guard, provider)
        result = await service.chat('second-client', request(mode='proactive', event='error'))
        self.assertEqual(result['proposals'], [])
        self.assertEqual([t['name'] for t in provider.payloads[0]['tools']], ['get_journey_status'])
    async def test_client_histories_are_isolated(self):
        provider = FakeProvider([answer(), answer()])
        service = AssistantService(self.settings, self.guard, provider)
        body = request()
        await service.chat('a', body)
        body.request_id = uuid4()
        await service.chat('b', body)
        self.assertEqual(len(provider.payloads[1]['input']), 1)
    async def test_invalid_usage_keeps_conservative_reservation(self):
        invalid = answer()
        invalid['usage']['input_tokens'] = -1
        with self.assertRaises(AssistantError) as error:
            await AssistantService(self.settings, self.guard, FakeProvider([invalid])).chat('client', request())
        self.assertEqual(error.exception.code, 'invalid_usage')
        self.assertEqual(self.guard.usage('client')['spent_usd'], .05)
    async def test_stale_context_never_calls_provider(self):
        provider = FakeProvider()
        body = request()
        body.context.captured_at = datetime.now(timezone.utc) - timedelta(seconds=40)
        with self.assertRaises(AssistantError) as error:
            await AssistantService(self.settings, self.guard, provider).chat('client', body)
        self.assertEqual(error.exception.code, 'stale_context')
        self.assertEqual(provider.payloads, [])
    async def test_timeout_and_unknown_provider_failure_do_not_refund_budget(self):
        class Slow:
            async def create(self, payload): await asyncio.sleep(1)
        settings = AssistantSettings(api_key='x', signing_secret='x'*40, pairing_code='x'*16,
            timeout_seconds=.01, state_path=self.settings.state_path)
        with self.assertRaises(AssistantError) as error:
            await AssistantService(settings, self.guard, Slow()).chat('client', request())
        self.assertEqual(error.exception.code, 'timeout')
        self.assertEqual(self.guard.usage('client')['spent_usd'], .05)
    async def test_image_is_resized_stripped_and_not_saved_in_history(self):
        output = io.BytesIO(); Image.new('RGB', (1200, 900)).save(output, format='JPEG')
        encoded = base64.b64encode(output.getvalue()).decode()
        prepared = prepare_image(encoded)
        image = Image.open(io.BytesIO(base64.b64decode(prepared.split(',')[1])))
        self.assertLessEqual(max(image.size), 768)
        provider = FakeProvider()
        body = request(image_base64=encoded)
        body.context.image_captured_at = datetime.now(timezone.utc)
        service = AssistantService(self.settings, self.guard, provider)
        result = await service.chat('client', body)
        self.assertEqual(result['safety'], 'advisory_only')
        self.assertEqual(provider.payloads[0]['input'][0]['content'][1]['type'], 'input_image')
        self.assertNotIn('base64', str(service.sessions))
    async def test_invalid_image_returns_400_without_reserving_or_charging_budget(self):
        provider = FakeProvider()
        body = request(image_base64=base64.b64encode(b'not-an-image').decode())
        body.context.image_captured_at = datetime.now(timezone.utc)
        service = AssistantService(self.settings, self.guard, provider)
        with patch.object(self.guard, 'reserve', wraps=self.guard.reserve) as reserve_spy:
            with self.assertRaises(AssistantError) as error:
                await service.chat('client', body)
            self.assertEqual(error.exception.status, 400)
            self.assertEqual(error.exception.code, 'invalid_image')
            reserve_spy.assert_not_called()
        self.assertEqual(self.guard.usage('client')['spent_usd'], 0)
        self.assertEqual(provider.payloads, [])
    def test_safety_confirmation_and_ai_directions_are_filtered(self):
        context = request().context
        for text in ['Phía trước an toàn, có thể đi tiếp.', 'You may proceed, the path is safe.', 'Rẽ trái ngay.']:
            self.assertIn('chưa thể xác nhận', sanitize_answer(FinalAnswer(kind='information', text=text), context, False))
        self.assertEqual(sanitize_answer(FinalAnswer(kind='route_status', text='AI invented direction'), context, False),
            'Chỉ dẫn do bộ dẫn đường cung cấp: Sau 20 mét, rẽ trái')


class EndpointTests(unittest.TestCase, Fixture):
    def setUp(self):
        self.setup()
        self.provider = FakeProvider()
        self.service = AssistantService(self.settings, self.guard, self.provider)
        self.patches = [patch.object(assistant_router, 'guard', self.guard), patch.object(assistant_router, 'settings', self.settings),
                        patch.object(assistant_router, 'service', self.service)]
        for p in self.patches: p.start()
        app = FastAPI()
        app.include_router(assistant_router.router)
        app.add_middleware(assistant_router.AssistantBoundary)
        @app.exception_handler(AssistantError)
        async def failure(request, error): return assistant_router.error_response(error)
        self.client = TestClient(app, base_url='https://testserver')
    def tearDown(self):
        self.client.close()
        for p in self.patches: p.stop()
        self.teardown()
    def test_unauthenticated_image_body_is_rejected_before_provider(self):
        response = self.client.post('/assistant/chat', content='x' * 5000)
        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.provider.payloads, [])
        self.assertNotIn('test-key-not-real', response.text)
    def test_plaintext_assistant_access_is_refused(self):
        response = self.client.get('http://testserver/assistant/status')
        self.assertEqual(response.status_code, 426)
    def test_pair_authenticated_chat_and_body_limit(self):
        token = self.client.post('/assistant/pair', json={'code': 'pairing-test-code', 'device_id': str(uuid4())}).json()['access_token']
        headers = {'Authorization': 'Bearer ' + token}
        response = self.client.post('/assistant/chat', headers=headers, json=request().model_dump(mode='json'))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers['cache-control'], 'no-store')
        response = self.client.post('/assistant/chat', headers=headers, content=b'x' * 1300001)
        self.assertEqual(response.status_code, 413)
        response = self.client.post('/assistant/unpair', headers=headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.client.get('/assistant/status', headers=headers).status_code, 401)


class _FakeHTTPResponse:
    def __init__(self, status_code=200, data=None):
        self.status_code = status_code
        self._data = data if data is not None else {}
        self.text = json.dumps(self._data)

    def json(self):
        return self._data


class GeminiProviderTests(unittest.IsolatedAsyncioTestCase, Fixture):
    def setUp(self):
        self.setup()
        self.gemini_settings = AssistantSettings(
            api_key='gemini-test-placeholder',
            signing_secret='x' * 40,
            pairing_code='pairing-test-code',
            provider='gemini',
            model='gemini-3.5-flash-lite',
            input_usd_per_1m=0.30,
            output_usd_per_1m=2.50,
            state_path=self.settings.state_path,
        )

    def tearDown(self):
        self.teardown()

    def _env(self, **overrides):
        base = {
            'ASSISTANT_SIGNING_SECRET': 's' * 40,
            'ASSISTANT_PAIRING_CODE': 'p' * 16,
        }
        base.update(overrides)
        return base

    def test_provider_selection_matrix_and_fail_closed_cases(self):
        # 1. Neither key set -> disabled, defaults preserved
        with patch('assistant_config.dotenv_values', return_value=self._env()):
            s = AssistantSettings.load()
            self.assertFalse(s.enabled)
            self.assertEqual(s.provider, 'openai')
            self.assertEqual(s.model, 'gpt-4.1-mini')

        # 2. Only OPENAI_API_KEY set -> openai selected
        with patch('assistant_config.dotenv_values', return_value=self._env(OPENAI_API_KEY='oa-placeholder')):
            s = AssistantSettings.load()
            self.assertTrue(s.enabled)
            self.assertEqual(s.provider, 'openai')
            self.assertEqual(s.model, 'gpt-4.1-mini')
            self.assertEqual((s.input_usd_per_1m, s.output_usd_per_1m), (0.40, 1.60))

        # 3. Only GEMINI_API_KEY set -> gemini selected with default model gemini-3.5-flash-lite
        with patch('assistant_config.dotenv_values', return_value=self._env(GEMINI_API_KEY='gm-placeholder')):
            s = AssistantSettings.load()
            self.assertTrue(s.enabled)
            self.assertEqual(s.provider, 'gemini')
            self.assertEqual(s.model, 'gemini-3.5-flash-lite')
            self.assertEqual((s.input_usd_per_1m, s.output_usd_per_1m), (0.30, 2.50))

        # 4. Both keys set, ASSISTANT_PROVIDER unset -> openai wins
        with patch('assistant_config.dotenv_values', return_value=self._env(
                OPENAI_API_KEY='oa-placeholder', GEMINI_API_KEY='gm-placeholder')):
            s = AssistantSettings.load()
            self.assertTrue(s.enabled)
            self.assertEqual(s.provider, 'openai')
            self.assertEqual(s.model, 'gpt-4.1-mini')

        # 5. Both keys set, ASSISTANT_PROVIDER=gemini -> gemini wins
        with patch('assistant_config.dotenv_values', return_value=self._env(
                ASSISTANT_PROVIDER='gemini', OPENAI_API_KEY='oa-placeholder', GEMINI_API_KEY='gm-placeholder',
                GEMINI_ASSISTANT_MODEL='gemini-3.5-flash-lite')):
            s = AssistantSettings.load()
            self.assertTrue(s.enabled)
            self.assertEqual(s.provider, 'gemini')
            self.assertEqual(s.model, 'gemini-3.5-flash-lite')
            self.assertEqual((s.input_usd_per_1m, s.output_usd_per_1m), (0.30, 2.50))

        # 6. ASSISTANT_PROVIDER=gemini but GEMINI_API_KEY missing -> disabled even if OPENAI_API_KEY present
        with patch('assistant_config.dotenv_values', return_value=self._env(
                ASSISTANT_PROVIDER='gemini', OPENAI_API_KEY='oa-placeholder')):
            s = AssistantSettings.load()
            self.assertFalse(s.enabled)

        # 7. ASSISTANT_PROVIDER=openai but OPENAI_API_KEY missing -> disabled even if GEMINI_API_KEY present
        with patch('assistant_config.dotenv_values', return_value=self._env(
                ASSISTANT_PROVIDER='openai', GEMINI_API_KEY='gm-placeholder')):
            s = AssistantSettings.load()
            self.assertFalse(s.enabled)

        # 8. Unknown ASSISTANT_PROVIDER -> fail closed
        with patch('assistant_config.dotenv_values', return_value=self._env(
                ASSISTANT_PROVIDER='other', OPENAI_API_KEY='oa-placeholder', GEMINI_API_KEY='gm-placeholder')):
            s = AssistantSettings.load()
            self.assertFalse(s.enabled)

        # 9. Disallowed GEMINI_ASSISTANT_MODEL -> fail closed
        with patch('assistant_config.dotenv_values', return_value=self._env(
                GEMINI_API_KEY='gm-placeholder', GEMINI_ASSISTANT_MODEL='gemini-1.5-pro')):
            s = AssistantSettings.load()
            self.assertFalse(s.enabled)

        # 10. AssistantService selects provider class from settings when none injected
        self.assertIsInstance(AssistantService(self.settings, self.guard).provider, OpenAIResponses)
        self.assertIsInstance(AssistantService(self.gemini_settings, self.guard).provider, GeminiResponses)
        self.assertIsInstance(build_provider(self.gemini_settings), GeminiResponses)
        self.assertIn('GEMINI_API_KEY', check_secret_boundary.SECRET_KEYS)

    def test_schema_and_request_translation(self):
        provider = GeminiResponses(self.gemini_settings)
        answer_schema = gemini_schema(strict_answer_schema())
        dump = json.dumps(answer_schema)
        self.assertNotIn('$defs', dump)
        self.assertNotIn('$ref', dump)
        self.assertNotIn('additionalProperties', dump)
        self.assertNotIn('maxLength', dump)
        self.assertNotIn('title', dump)
        self.assertEqual(answer_schema['properties']['observations']['items']['type'], 'object')

        tool_schema = gemini_schema(ToolArguments.model_json_schema())
        self.assertEqual(tool_schema['properties']['place_id'], {'type': 'string', 'nullable': True})

        call_id = 'call_123'
        payload = {
            'model': 'gemini-3.5-flash-lite',
            'instructions': 'System rules',
            'input': [
                {'role': 'user', 'content': 'Previous question'},
                {'role': 'assistant', 'content': 'Previous answer'},
                {'role': 'user', 'content': [
                    {'type': 'input_text', 'text': '{"message":"Current"}'},
                    {'type': 'input_image', 'image_url': 'data:image/jpeg;base64,QUJDRA==', 'detail': 'low'},
                ]},
                {'type': 'function_call', 'name': 'search_places', 'call_id': call_id,
                 'arguments': '{"query":"công viên"}', 'thought_signature': 'sig-1'},
                {'type': 'function_call_output', 'call_id': call_id,
                 'output': '{"place_id":"p1","display_name":"Công viên"}'},
            ],
            'tools': TOOLS,
            'tool_choice': 'auto',
            'max_output_tokens': 500,
            'text': {'format': {'type': 'json_schema', 'name': 'navigation_assistant_reply',
                                'strict': True, 'schema': strict_answer_schema()}},
        }

        # Tool-enabled round: includes tools + toolConfig AUTO, omits responseSchema from generationConfig
        req_auto = provider.translate_request(payload)
        self.assertIn('System rules', req_auto['systemInstruction']['parts'][0]['text'])
        self.assertEqual(req_auto['toolConfig'], {'functionCallingConfig': {'mode': 'AUTO'}})
        self.assertEqual(len(req_auto['tools'][0]['functionDeclarations']), 3)
        self.assertNotIn('responseSchema', req_auto['generationConfig'])
        self.assertNotIn('responseMimeType', req_auto['generationConfig'])
        self.assertEqual(req_auto['generationConfig']['maxOutputTokens'], 500)
        self.assertEqual(req_auto['generationConfig']['thinkingConfig'], {'thinkingLevel': 'minimal'})
        self.assertEqual(req_auto['contents'][2]['parts'][1],
                         {'inlineData': {'mimeType': 'image/jpeg', 'data': 'QUJDRA=='}})
        self.assertEqual(req_auto['contents'][3], {
            'role': 'model',
            'parts': [{'functionCall': {'name': 'search_places', 'args': {'query': 'công viên'}},
                       'thoughtSignature': 'sig-1'}],
        })
        self.assertEqual(req_auto['contents'][4], {
            'role': 'user',
            'parts': [{'functionResponse': {'name': 'search_places',
                                            'response': {'place_id': 'p1', 'display_name': 'Công viên'}}}],
        })

        # Forced function choice (used by smoke_assistant.py)
        req_forced = provider.translate_request({**payload, 'tool_choice': {'type': 'function', 'name': 'get_journey_status'}})
        self.assertEqual(req_forced['toolConfig'], {
            'functionCallingConfig': {'mode': 'ANY', 'allowedFunctionNames': ['get_journey_status']}
        })

        # Final schema-only round (tool_choice="none"): includes responseMimeType + responseSchema, omits tools
        req_none = provider.translate_request({**payload, 'tool_choice': 'none'})
        self.assertNotIn('tools', req_none)
        self.assertEqual(req_none['generationConfig']['responseMimeType'], 'application/json')
        self.assertEqual(req_none['generationConfig']['responseSchema'], answer_schema)

    async def test_gemini_end_to_end_tool_round_final_answer_cost_and_header_security(self):
        provider = GeminiResponses(self.gemini_settings)
        guard = AssistantGuard(self.gemini_settings, clock=lambda: self.clock)
        service = AssistantService(self.gemini_settings, guard, provider)

        calls_seen = []
        gemini_replies = [
            _FakeHTTPResponse(200, {
                'candidates': [{
                    'finishReason': 'STOP',
                    'content': {'role': 'model', 'parts': [
                        {'functionCall': {'name': 'get_journey_status', 'args': {}}}
                    ]},
                }],
                'usageMetadata': {'promptTokenCount': 1000, 'candidatesTokenCount': 100, 'thoughtsTokenCount': 0},
            }),
            _FakeHTTPResponse(200, {
                'candidates': [{
                    'finishReason': 'STOP',
                    'content': {'role': 'model', 'parts': [
                        {'text': json.dumps({
                            'kind': 'information',
                            'text': 'Tuyến đi bộ được cập nhật từ GPS.',
                            'observations': [],
                            'interpretation': [],
                            'recommendations': [],
                        })}
                    ]},
                }],
                'usageMetadata': {'promptTokenCount': 1000, 'candidatesTokenCount': 100, 'thoughtsTokenCount': 0},
            }),
        ]

        async def fake_post(_client, url, headers=None, json=None):
            calls_seen.append((url, headers, json))
            return gemini_replies.pop(0)

        with patch.object(httpx.AsyncClient, 'post', new=fake_post):
            result = await service.chat('client', request())

        self.assertEqual(len(calls_seen), 2)
        for url, headers, _ in calls_seen:
            self.assertNotIn(self.gemini_settings.api_key, url)
            self.assertNotIn('key=', url)
            self.assertEqual(headers.get('x-goog-api-key'), self.gemini_settings.api_key)
        # Second call had functionResponse from round 1
        self.assertEqual(calls_seen[1][2]['contents'][-1]['parts'][0]['functionResponse']['name'], 'get_journey_status')
        # Cost: 2000 input tokens * $0.30/1M + 200 output tokens * $2.50/1M = 0.0006 + 0.0005 = 0.0011 USD
        self.assertAlmostEqual(result['usage_usd'], 0.0011, places=6)
        self.assertAlmostEqual(guard.usage('client')['spent_usd'], 0.0011, places=6)

    async def test_gemini_two_step_schema_fallback_when_auto_round_returns_plain_text(self):
        provider = GeminiResponses(self.gemini_settings)
        guard = AssistantGuard(self.gemini_settings, clock=lambda: self.clock)
        service = AssistantService(self.gemini_settings, guard, provider)

        bodies = []
        replies = [
            _FakeHTTPResponse(200, {
                'candidates': [{'finishReason': 'STOP', 'content': {'parts': [{'text': 'Not valid JSON yet'}]}}],
                'usageMetadata': {'promptTokenCount': 300, 'candidatesTokenCount': 20},
            }),
            _FakeHTTPResponse(200, {
                'candidates': [{'finishReason': 'STOP', 'content': {'parts': [
                    {'text': json.dumps({'kind': 'information', 'text': 'Phản hồi chuẩn schema.'})}
                ]}}],
                'usageMetadata': {'promptTokenCount': 300, 'candidatesTokenCount': 30},
            }),
        ]

        async def fake_post(_client, url, headers=None, json=None):
            bodies.append(json)
            return replies.pop(0)

        with patch.object(httpx.AsyncClient, 'post', new=fake_post):
            result = await service.chat('client', request())

        self.assertEqual(len(bodies), 2)
        self.assertIn('tools', bodies[0])
        self.assertNotIn('tools', bodies[1])
        self.assertEqual(bodies[1]['generationConfig']['responseMimeType'], 'application/json')
        self.assertIn('responseSchema', bodies[1]['generationConfig'])
        self.assertIn('Phản hồi chuẩn schema.', result['text'])

    async def test_gemini_blocked_empty_and_http_errors_map_cleanly_without_leaking_secrets(self):
        provider = GeminiResponses(self.gemini_settings)
        guard = AssistantGuard(self.gemini_settings, clock=lambda: self.clock)
        service = AssistantService(self.gemini_settings, guard, provider)

        for blocked_payload in [
            {'promptFeedback': {'blockReason': 'SAFETY'}, 'usageMetadata': {'promptTokenCount': 50}},
            {'candidates': [{'finishReason': 'SAFETY', 'content': {'parts': []}}], 'usageMetadata': {'promptTokenCount': 50}},
            {'candidates': []},
        ]:
            with patch.object(httpx.AsyncClient, 'post', return_value=_FakeHTTPResponse(200, blocked_payload)):
                with self.assertRaises(AssistantError) as ctx:
                    await service.chat('client-' + str(uuid4()), request())
                self.assertEqual(ctx.exception.status, 502)
                self.assertEqual(ctx.exception.code, 'incomplete')
                self.assertNotIn(self.gemini_settings.api_key, str(ctx.exception))

        for status_code, expected_code in [(401, 'provider_credentials'), (403, 'provider_credentials'),
                                           (429, 'provider_limit'), (500, 'provider_error')]:
            secret_body = {'error': {'message': 'leaked-detail-' + self.gemini_settings.api_key}}
            with patch.object(httpx.AsyncClient, 'post', return_value=_FakeHTTPResponse(status_code, secret_body)):
                with self.assertRaises(AssistantError) as ctx:
                    await service.chat('client-' + str(uuid4()), request())
                self.assertEqual(ctx.exception.status, 502)
                self.assertEqual(ctx.exception.code, expected_code)
                self.assertNotIn('leaked-detail', str(ctx.exception))
                self.assertNotIn(self.gemini_settings.api_key, str(ctx.exception))


if __name__ == '__main__': unittest.main()

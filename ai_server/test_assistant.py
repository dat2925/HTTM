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
from PIL import Image
from fastapi import FastAPI
from fastapi.testclient import TestClient
from assistant_config import AssistantSettings
from assistant_guard import AssistantGuard, AssistantError
from assistant_models import ChatRequest, FinalAnswer
from assistant_service import AssistantService, sanitize_answer, prepare_image
import assistant_router


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


if __name__ == '__main__': unittest.main()

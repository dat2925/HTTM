import json
import unittest
from datetime import datetime, timedelta, timezone
from assistant_models import FinalAnswer, GroundedStatement, Obstacle
from assistant_guidance import current_context, render_guidance
from assistant_service import strict_answer_schema, AssistantService
from test_assistant import request, FakeProvider, Fixture, answer


class GuidanceTests(unittest.TestCase):
    def test_ordinary_conversation_and_explanations_survive(self):
        for text in ['Xin chào, tôi có thể giải thích GPS.', 'Tôi không có thông tin giờ mở cửa.',
                     'Cụm từ rẽ trái có nghĩa là đổi hướng về phía trái.',
                     'Bạn nên dừng lại để kiểm tra vật cản.', 'Rẽ trái có nghĩa là đổi hướng về phía trái.',
                     'Hãy tìm nơi an toàn để chờ hỗ trợ.', 'Walking can be a form of exercise.',
                     'Đèn xanh dành cho người đi bộ vẫn cần được kiểm tra tại chỗ.']:
            with self.subTest(text=text):
                self.assertEqual(render_guidance(FinalAnswer(kind='information', text=text), request().context, False)[0], text)

    def test_unclear_image_and_sourced_observation_are_allowed(self):
        context = request().context
        context.image_captured_at = datetime.now(timezone.utc)
        result, guidance = render_guidance(FinalAnswer(kind='observation', text='', observations=[
            GroundedStatement(text='Tôi không thấy rõ biển báo trong ảnh.', sources=['camera'])]), context, True)
        self.assertIn('không thấy rõ biển báo', result)
        self.assertEqual(guidance['evidence_sources'], ['camera'])

    def test_kind_and_sources_do_not_authorize_unsafe_claims(self):
        context = request().context
        context.image_captured_at = datetime.now(timezone.utc)
        for text in ['Bạn có thể rẽ trái vì không có xe.', 'Phía trước an toàn.',
                     'Bạn có thể sang đường.', 'Xe cách bạn 2 mét.', 'Lách sang phải.',
                     'Không có vật cản, đường trống.', 'Tôi chưa thể xác nhận, bạn có thể rẽ trái.',
                     'Tôi chưa xác định được lối đi nhưng bạn có thể sang đường.']:
            for kind in ['information', 'observation', 'situation', 'precaution']:
                with self.subTest(text=text, kind=kind):
                    result, _ = render_guidance(FinalAnswer(kind=kind, text='', observations=[
                        GroundedStatement(text=text, sources=['camera'])]), context, True)
                    self.assertNotIn(text, result)
                    self.assertIn('chưa thể xác nhận', result)

    def test_retains_observation_when_unsafe_clause_removed(self):
        context = request().context
        context.image_captured_at = datetime.now(timezone.utc)
        result, _ = render_guidance(FinalAnswer(kind='situation', text='', observations=[
            GroundedStatement(text='Trong ảnh có xe máy. Bạn có thể rẽ trái vì không có xe.', sources=['camera'])],
            recommendations=['stop_and_check']), context, True)
        self.assertIn('Trong ảnh có xe máy.', result)
        self.assertNotIn('Bạn có thể rẽ trái', result)
        result, _ = render_guidance(FinalAnswer(kind='observation', text='Trong ảnh có xe máy, bạn có thể rẽ trái.'), context, True)
        self.assertIn('Trong ảnh có xe máy.', result)
        self.assertNotIn('bạn có thể rẽ trái', result)

    def test_source_labels_cannot_fabricate_observations(self):
        context = request().context
        result, _ = render_guidance(FinalAnswer(kind='observation', text='', observations=[
            GroundedStatement(text='Có ô tô phía trước.', sources=['gps'])]), context, False)
        self.assertNotIn('ô tô', result)
        self.assertIn('GPS báo sai số', result)

    def test_expired_and_future_sources_cannot_support_claims(self):
        now = datetime.now(timezone.utc)
        for delta in [-20, 30]:
            context = request().context
            context.yolo_updated_at = now + timedelta(seconds=delta)
            context.image_captured_at = now + timedelta(seconds=delta)
            context.obstacles = [Obstacle(class_name='car', position='center', danger='high', confidence=.9)]
            clean, sources = current_context(context, True, now)
            self.assertFalse(sources['yolo'])
            self.assertFalse(sources['camera'])
            self.assertEqual(clean.obstacles, [])
            result, _ = render_guidance(FinalAnswer(kind='observation', text='', observations=[
                GroundedStatement(text='Có ô tô.', sources=['yolo'])]), context, True, now)
            self.assertNotIn('Có ô tô.', result)

    def test_no_route_still_supports_situation_advice(self):
        context = request().context
        context.status = 'idle'
        result, _ = render_guidance(FinalAnswer(kind='situation', text='', interpretation=[
            GroundedStatement(text='Theo mô tả, xe có thể chắn lối đi.', sources=['user'])],
            recommendations=['stop_and_check', 'ask_assistance']), context, False)
        self.assertIn('có thể chắn lối', result)
        self.assertIn('dừng lại', result)

    def test_stale_gps_cannot_supply_route_directions(self):
        context = request().context
        context.gps_updated_at -= timedelta(seconds=30)
        result, _ = render_guidance(FinalAnswer(kind='route_status', text='Rẽ phải'), context, False)
        self.assertNotIn('rẽ trái', result)
        self.assertIn('kiểm tra GPS', result)

    def test_schema_required_fields_include_nested_objects(self):
        schema = strict_answer_schema()
        for node in [schema, schema['$defs']['GroundedStatement']]:
            self.assertEqual(set(node['required']), set(node['properties']))
            self.assertFalse(node['additionalProperties'])


class SituationServiceTests(unittest.IsolatedAsyncioTestCase, Fixture):
    def setUp(self): self.setup()
    def tearDown(self): self.teardown()

    async def test_api_does_not_send_expired_detections_or_gps(self):
        body = request()
        body.context.gps_updated_at -= timedelta(seconds=30)
        body.context.yolo_updated_at = datetime.now(timezone.utc) - timedelta(seconds=8)
        body.context.obstacles = [Obstacle(class_name='car', position='center', danger='high', confidence=.9)]
        provider = FakeProvider([answer('Tôi có thể giải thích GPS.')])
        result = await AssistantService(self.settings, self.guard, provider).chat('client', body)
        sent = json.loads(provider.payloads[0]['input'][0]['content'][0]['text'])
        self.assertIsNone(sent['reported_context']['position'])
        self.assertEqual(sent['reported_context']['obstacles'], [])
        self.assertIn('guidance', result)

    async def test_evidence_expiring_while_model_runs_is_not_rendered(self):
        body = request()
        body.context.yolo_updated_at = datetime.now(timezone.utc)
        body.context.obstacles = [Obstacle(class_name='car', position='center', danger='high', confidence=.9)]
        def slow_result(payload):
            body.context.yolo_updated_at -= timedelta(seconds=20)
            response = answer('', 'observation')
            response['output'][0]['content'][0]['text'] = json.dumps({'kind': 'observation', 'text': '',
                'observations': [{'text': 'YOLO phát hiện ô tô.', 'sources': ['yolo']}],
                'interpretation': [], 'recommendations': ['stop_and_check']})
            return response
        result = await AssistantService(self.settings, self.guard, FakeProvider([slow_result])).chat('client', body)
        self.assertNotIn('YOLO phát hiện ô tô', result['text'])
        self.assertEqual(result['guidance']['evidence_sources'], [])
        self.assertIn('dừng lại', result['text'])

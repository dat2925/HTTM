"""Explicit opt-in live API check. Only synthetic image/context; never print keys."""
import argparse
import asyncio
import base64
import io
from datetime import datetime, timezone
from uuid import uuid4
from PIL import Image
from assistant_config import AssistantSettings
from assistant_guard import AssistantGuard, AssistantError
from assistant_models import ChatRequest
from assistant_service import AssistantService, OpenAIResponses


class SmokeProvider(OpenAIResponses):
    def __init__(self, settings):
        super().__init__(settings)
        self.calls = self.tool_calls = 0
    async def create(self, payload):
        if self.calls == 0:
            payload = {**payload, "tool_choice": {"type": "function", "name": "get_journey_status"}}
        self.calls += 1
        response = await super().create(payload)
        self.tool_calls += sum(item.get('type') == 'function_call' for item in response.get('output', []))
        return response


async def main():
    settings = AssistantSettings.load()
    guard = AssistantGuard(settings)
    guard.require_enabled()
    provider = SmokeProvider(settings)
    image = io.BytesIO()
    Image.new('RGB', (64, 64), (20, 90, 220)).save(image, format='JPEG')
    now = datetime.now(timezone.utc)
    body = ChatRequest.model_validate({'request_id': str(uuid4()), 'conversation_id': str(uuid4()),
        'message': 'Mô tả màu chủ đạo ảnh kiểm thử và trạng thái được báo. Không chỉ dẫn di chuyển.',
        'image_base64': base64.b64encode(image.getvalue()).decode(),
        'context': {'captured_at': now, 'image_captured_at': now, 'status': 'idle', 'route_message': 'Chưa đặt điểm đến.'}})
    result = await AssistantService(settings, guard, provider).chat('local-smoke-test', body)
    print({'live_check': 'passed', 'model': settings.model, 'api_calls': provider.calls,
        'function_calls': provider.tool_calls, 'synthetic_image': True, 'safety': result['safety'], 'usage_usd': result['usage_usd']})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()
    if not args.live: parser.error('Use --live to explicitly make bounded paid API calls.')
    try: asyncio.run(main())
    except AssistantError as error:
        print({'live_check': 'failed', 'code': error.code, 'message': error.message})
        raise SystemExit(1)

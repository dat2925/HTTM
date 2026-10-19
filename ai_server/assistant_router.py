import json
import ipaddress
from fastapi import APIRouter, Request
from starlette.responses import JSONResponse
from assistant_config import AssistantSettings
from assistant_guard import AssistantError, AssistantGuard
from assistant_models import ChatRequest, PairRequest
from assistant_service import AssistantService

settings = AssistantSettings.load()
guard = AssistantGuard(settings)
service = AssistantService(settings, guard)
router = APIRouter(prefix="/assistant", tags=["assistant"])


def error_response(error: AssistantError):
    return JSONResponse({"error": {"code": error.code, "message": error.message}}, status_code=error.status,
                        headers={"Cache-Control": "no-store"})


class AssistantBoundary:
    """Authenticate before reading image bodies, and cap actual chunked body size."""
    def __init__(self, app): self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not scope["path"].startswith("/assistant/"):
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers", []))
        try:
            guard.require_enabled()
            remote = scope.get('client', ('', 0))[0]
            try: local = ipaddress.ip_address(remote).is_private or ipaddress.ip_address(remote).is_loopback
            except ValueError: local = False
            if scope.get('scheme') != 'https' and not (settings.allow_insecure_lan and local):
                raise AssistantError(426, 'https_required', 'Endpoint trợ lý yêu cầu HTTPS.')
            if scope["path"] != "/assistant/pair":
                client = guard.authenticate(headers.get(b"authorization", b"").decode("latin1"))
                scope.setdefault("state", {})["assistant_client"] = client
            limit = 4096 if scope["path"] == "/assistant/pair" else 1300000
            if int(headers.get(b"content-length", b"0")) > limit:
                raise AssistantError(413, "body_limit", "Yêu cầu vượt giới hạn kích thước.")
            body = bytearray()
            while True:
                part = await receive()
                if part["type"] == "http.disconnect": return
                body.extend(part.get("body", b""))
                if len(body) > limit:
                    raise AssistantError(413, "body_limit", "Yêu cầu vượt giới hạn kích thước.")
                if not part.get("more_body", False): break
            delivered = False
            async def bounded_receive():
                nonlocal delivered
                if not delivered:
                    delivered = True
                    return {"type": "http.request", "body": bytes(body), "more_body": False}
                return await receive()
            async def private_send(message):
                if message["type"] == "http.response.start":
                    if not any(key == b'cache-control' for key, _ in message.get('headers', [])):
                        message.setdefault("headers", []).append((b"cache-control", b"no-store"))
                await send(message)
            await self.app(scope, bounded_receive, private_send)
        except AssistantError as error:
            await error_response(error)(scope, receive, send)
        except (ValueError, UnicodeError):
            await error_response(AssistantError(400, "invalid_request", "Yêu cầu không hợp lệ."))(scope, receive, send)


@router.post("/pair")
async def pair(body: PairRequest, request: Request):
    remote = request.client.host if request.client else "unknown"
    return guard.pair(body.code, str(body.device_id), remote)


@router.get("/status")
async def status(request: Request):
    client = request.state.assistant_client
    return {"enabled": True, "model": settings.model, "usage": guard.usage(client)}


@router.post("/chat")
async def chat(body: ChatRequest, request: Request):
    return await service.chat(request.state.assistant_client, body)


@router.post("/reset")
async def reset(request: Request):
    service.clear_history(request.state.assistant_client)
    return {"success": True}


@router.post("/unpair")
async def unpair(request: Request):
    client = request.state.assistant_client
    guard.revoke(client)
    service.clear_history(client)
    return {"success": True}

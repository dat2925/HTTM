# Smart Navigation server v2

FastAPI + YOLO11n + Valhalla **pedestrian** + Nominatim search/reverse.

```powershell
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000
```

Python 3.11 or newer is required for the assistant's `asyncio.timeout`. Create the environment with `py -3.11 -m venv ai_server/.venv` from the repository root first. Commands above run from `ai_server`. Health: `/health`; interactive API: `/docs`.

Routing: `/route?from_lat=&from_lng=&to_lat=&to_lng=`. Returns `profile=pedestrian`, geometry `[lat,lng]`, shape-indexed maneuvers, distance/time. Uses `VALHALLA_URL` (default `https://valhalla1.openstreetmap.de`); no driving fallback. Public service needs Internet; self-host for sustained production traffic.

Geocoding: `/geocode?q=&near_lat=&near_lng=`; `/reverse?lat=&lng=`. Nominatim requests share a per-process 1.1-second interval and 5-minute bounded cache. Run one worker; multi-worker deployment needs shared throttling/cache.

Detection: `/detect` multipart JPEG; model selected with `YOLO_MODEL`, confidence with `YOLO_CONFIDENCE`. Proximity remains a bounding-box heuristic.

Tests: `.venv\Scripts\python.exe -X utf8 -B -m unittest discover -p "test_*.py" -v`.

See [handoff](../docs/HANDOFF_PEDESTRIAN.md) for contract changes and phone validation.

Optional OpenAI Assistant: `OPENAI_API_KEY` is read only from this directory's `.env`.
For a new clone, copy `.env.example` to `.env` only if it does not exist, then set the key locally. Never copy secrets from the reference fork or into Flutter assets.
Run `python setup_assistant.py` to provision signing/pairing secrets; use
`--show-pairing-code` to give the device its pairing code, never the OpenAI key.
Assistant endpoints require HTTPS, device bearer auth, and persistent SQLite
rate/spend limits. No tool directly changes navigation. Defaults: 1 USD/day total,
0.5 USD/day/device, 6 turns/min/device, 0.05 USD maximum reservation/turn.
See [OpenAI handoff](../docs/HANDOFF_OPENAI_ASSISTANT.md) for configuration and local
HTTP debug exceptions. Navigation endpoints remain independent of assistant configuration.

Run `python setup_assistant.py --qr` to create `.assistant-state/pairing-qr.png`
locally. Keep it private: it contains the device pairing credential, not the OpenAI
key or signing secret. It is ignored by Git and is not served by the backend.
Scan it in the app's pairing screen, then press Pair. Existing secrets are preserved.

# Smart Navigation for Visually Impaired People

An Android Flutter app with a live OpenStreetMap, GPS/compass guidance,
Valhalla pedestrian routing, a persisted walked trail and periodic replanning
of the remaining path. A FastAPI/YOLO server also detects selected obstacle
classes from a JPEG roughly every 900 ms, with Vietnamese TTS/haptic warnings.

See [DEMO_SETUP.md](DEMO_SETUP.md) for installation, network configuration,
run commands, pre-demo checks, scenarios, and the MVP's academic limitations.

Current pipeline:

`Camera -> HTTP -> YOLO11n -> bounding-box heuristic -> TTS/haptics`

Walking pipeline:

`Destination confirmation -> Valhalla pedestrian geometry -> GPS path matching -> map + TTS`

The walked GPS trail is kept separately from the remaining route. Routing refreshes
every 30 seconds when moving, and earlier after confirmed route deviation.
See [architecture](docs/ARCHITECTURE.md) and [implementation handoffs](docs/HANDOFF_PEDESTRIAN.md).

The bounding-box heuristic is not depth estimation. The planned production
replacement is monocular depth estimation plus walkable-area reasoning.

OpenAI Assistant is an optional backend-only integration: conversation, on-demand
camera analysis, GPS/route/YOLO context, and navigation proposals requiring user
confirmation. Core navigation keeps running independently. OpenAI credentials live
only in `ai_server/.env`; the Flutter `.env` remains the backend URL configuration.
See [assistant setup and handoff](docs/HANDOFF_OPENAI_ASSISTANT.md) for device pairing,
HTTPS, rate/spend limits, proactivity controls and validation.

The main microphone and typed conversation share a local command router:
established navigation commands stay in the core; other questions use the assistant.
Answers and proposal confirmation appear on the map screen. Device pairing supports
paste, show/hide, retry without clearing failed input, and QR scanning. Generate a
private local QR with `ai_server/.venv/Scripts/python.exe ai_server/setup_assistant.py --qr`.

Current restoration audit and test results: [RESTORATION_REPORT.md](docs/RESTORATION_REPORT.md).
The upstream [device handoff](docs/HANDOFF_PERSON_2.md) is retained as historical context.

# Smart Navigation for Visually Impaired People

A demo-ready Android Flutter app plus a local FastAPI/YOLO server. The phone
captures a JPEG roughly every 900 ms, the server detects selected obstacle
classes, and Flutter prioritizes a Vietnamese TTS and haptic warning.

Phần Người 2 và các phụ thuộc đã được khôi phục từ bản backup. Xem
[bàn giao Người 2](docs/HANDOFF_PERSON_2.md) để biết phạm vi file, kiểm thử
và cách chạy phiên bản hiện tại với `HomeScreen` / `SessionController`.

See [DEMO_SETUP.md](DEMO_SETUP.md) for installation, network configuration,
run commands, pre-demo checks, scenarios, and the MVP's academic limitations.

Current pipeline:

`Camera -> HTTP -> YOLO11n -> bounding-box heuristic -> TTS/haptics`

The bounding-box heuristic is not depth estimation. The planned production
replacement is monocular depth estimation plus walkable-area reasoning.

# AI Server

This service receives JPEG images and returns filtered YOLO detections. It uses
`yolo11n.pt`, a small pretrained nano model. The weights download automatically
on the first detection; run one test before the live demonstration.

```powershell
cd ai_server
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

Open `http://127.0.0.1:8000/health` and expect `{"status":"ok"}`. Interactive
API documentation is at `http://127.0.0.1:8000/docs`.

To use another compatible model, set `YOLO_MODEL` before starting the server.
The current danger value is only a bounding-box area heuristic—not depth.

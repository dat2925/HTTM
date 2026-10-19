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


## Optional OpenAI Assistant backend

The `/assistant/*` endpoints are optional and do not change the existing `/detect` API.
Configure `ai_server/.env` from `.env.example` and run `python ai_server/setup_assistant.py` for pairing setup. Keep `OPENAI_API_KEY` server-side only. Run `python -m unittest discover -s ai_server -p 'test_assistant.py'` and `python -m unittest discover -s ai_server -p 'test_pairing_qr.py'` for focused checks. See the fork's `docs/HANDOFF_OPENAI_ASSISTANT.md` for full setup and security guidance.

# Smart Navigation Demo Setup

## 1. Start the AI server

Use Python 3.10 or 3.11 (64-bit) for the smoothest PyTorch/Ultralytics setup.

```powershell
cd D:\dan_duong\ai_server
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

The first detection downloads `yolo11n.pt`. Start and test the server while an
internet connection is available, before the presentation. Windows Firewall may
ask you to allow Python on private networks; allow it for the phone to connect.

Verify on the laptop: `http://127.0.0.1:8000/health` must show
`{"status":"ok"}`.

## 2. Find the laptop IP

Run `ipconfig`, find the active Wi-Fi adapter, and copy its IPv4 address. The
current laptop address is `172.11.42.144`. The phone and laptop must use the
same Wi-Fi network.

## 3. Run the Flutter app

Connect an Android phone with USB debugging enabled, then run:

```powershell
cd D:\dan_duong
flutter pub get
flutter run --dart-define=AI_SERVER_URL=http://172.11.42.144:8000
```

Replace `172.11.42.144` if the laptop IPv4 address changes. This setting is
preferred; the fallback URL is defined once in `lib/config/ai_config.dart`.
Grant camera permission, confirm the preview appears, and press **Start AI**.

## 4. Pre-demo checklist

1. Keep the laptop plugged in and disable sleep.
2. Start the server and wait for the first model inference to finish.
3. Confirm `/health` from the phone browser using the laptop IP.
4. Launch the app with the correct `AI_SERVER_URL`.
5. Turn the phone media volume up and verify Vietnamese TTS is installed.

## 5. Demo scenarios

- Person centered: UI/TTS says `Phía trước có người.`
- Person close and centered: `Cảnh báo. Có người rất gần phía trước.`
- Person on the left: `Có người bên trái.` or the near variant.
- No filtered obstacle for three cycles: UI shows
  `Phía trước chưa phát hiện vật cản.`

The app sends one JPEG about every 900 ms and never overlaps requests. Repeated
warnings have a three-second cooldown. High danger triggers heavy haptic feedback.

## Academic limitation

The MVP estimates proximity only from the detected bounding-box area. It is not
physical distance or "Depth AI". A production version should replace this with
Depth Anything V2 Small or MiDaS, add walkable-area segmentation and obstacle
reasoning, and later consider TFLite/on-device inference for offline operation.

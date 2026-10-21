# Người 2 — YOLO và nền tảng thiết bị

Bản bàn giao độc lập cho luồng camera → YOLO → cảnh báo tiếng Việt/rung.
Chỉ giữ backend nhận diện, camera, STT/TTS, xử lý lệnh và bộ điều phối thiết bị.

Không chứa GPS/bản đồ/tìm tuyến, hội thoại AI, pairing/token hoặc triển khai trợ lý.
Các phần đó do Người 1 và Người 3 đưa vào dự án chung bằng commit của họ.

## Chạy

```powershell
python -m pip install -r ai_server/requirements.txt
python -m uvicorn main:app --app-dir ai_server --host 0.0.0.0 --port 8000
flutter pub get
flutter run --dart-define=AI_SERVER_URL=http://192.168.1.100:8000
```

Thay IP mẫu bằng IP máy chạy YOLO; mặc định `10.0.2.2:8000` dành cho Android emulator.
Cho phép camera và micro trên điện thoại. `.env` không được dùng trong bản này.
Lần nhận diện đầu có thể tải trọng số `yolo11n.pt`.

## Kiểm tra

```powershell
flutter analyze
flutter test
python -m unittest discover -s ai_server -p "test_*.py"
```

Xem [bàn giao Người 2](docs/HANDOFF_PERSON_2.md) để nối bộ điều phối với code của hai thành viên còn lại.

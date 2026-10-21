# Bàn giao Người 2: YOLO và nền tảng thiết bị

Khôi phục từ `D:\HTTM-source-backup.zip` vào `D:\HTTM-downloaded` ngày 14/10/2026.
Nguồn backup được giữ nguyên. Các thay đổi trong thư mục hiện tại chưa được commit/push.

## Phần Người 2

| Hạng mục | File |
| --- | --- |
| YOLO, kiểm tra ảnh và lỗi inference | `ai_server/detector.py`, endpoint `/detect` trong `ai_server/main.py` |
| Gửi ảnh và suy luận cảnh báo tiếng Việt | `lib/services/ai_detection_service.dart`, `lib/services/obstacle_reasoning_service.dart` |
| Model và giao diện nhận thức | `lib/models/detection_result.dart`, `lib/models/perception_frame.dart`, `lib/models/session_state.dart`, `lib/widgets/perception_preview.dart`, `lib/widgets/status_panel.dart` |
| Camera, STT, lệnh giọng nói, TTS | `lib/services/frame_source.dart`, `lib/services/voice_service.dart`, `lib/services/voice_command_router.dart`, `lib/services/tts_service.dart`, `lib/widgets/talk_button.dart` |
| Điều phối và lifecycle | `lib/controllers/session_controller.dart`, `lib/screens/home_screen.dart`, `lib/main.dart` |
| Nhường và khôi phục camera khi quét QR | `lib/screens/pairing_qr_screen.dart`, `lib/services/pairing_qr.dart`, các hàm `suspendCameraForQr` / `resumeCameraAfterQr` trong session controller |
| Quyền và cấu hình Android | `android/app/src/main/AndroidManifest.xml`, `android/gradle.properties` |
| Cấu hình và dependency Flutter | `lib/config/ai_config.dart`, `pubspec.yaml`, `pubspec.lock`, `.env.example` |

`detector.py`, `ai_detection_service.dart` và `obstacle_reasoning_service.dart` đã trùng nội dung backup trước khi khôi phục, nên Git có thể không liệt kê chúng là file thay đổi.

## Phụ thuộc được khôi phục cùng

Session controller và màn hình chính trong backup gọi trực tiếp module tuyến đường/GPS,
tìm địa điểm, lưu hành trình và trợ lý AI. Vì vậy các model, service, controller,
widget và màn hình hỗ trợ trong `lib/` cũng được khôi phục để app biên dịch và chạy.
Backend `main.py` dùng chung router trợ lý, geocoder và routing nên các module Python,
cấu hình mẫu và công cụ ghép nối liên quan được khôi phục cùng. Đây là phần hỗ trợ
tích hợp, không phải toàn bộ đều thuộc phạm vi đóng góp Người 2.

App khởi động vào `HomeScreen` với `SessionController`. Màn hình cũ
`ai_navigation_screen.dart` vẫn được giữ nhưng không còn là màn hình khởi động.
Không khôi phục `.venv`, cache, build hoặc cấu hình IDE từ ZIP.
`pubspec.lock` đã được Flutter điều chỉnh theo SDK đang cài trên máy.

## Luồng bàn giao

Camera → chụp frame → `/detect` → YOLO → suy luận vật cản → hiển thị cảnh báo
tiếng Việt → TTS ưu tiên 3 và haptic cho mức nguy hiểm vừa/cao.
Tiếng hướng dẫn đường ưu tiên 1, trợ lý AI ưu tiên 0. Nhấn giữ nút nói dừng TTS
trước khi nghe STT. Chỉ có một request nhận diện đang chạy; kết quả thuộc epoch
cũ sau dừng, pause hoặc nhường camera cho QR bị loại bỏ.

## Chạy trên máy

1. Chỉnh `AI_SERVER_URL` trong `.env` ở thư mục gốc sang địa chỉ backend thực tế.
   File này đã được tạo từ `.env.example`; IP mẫu `192.168.1.100` cần thay theo máy chạy server.
2. Dùng Python 3.11 trở lên cho toàn bộ backend, vì trợ lý AI dùng `asyncio.timeout`.
   `.venv` cũ dùng Python 3.9; `.venv-ai` dùng Python 3.10 được tạo để kiểm thử
   YOLO/endpoint/dẫn đường và không đủ phiên bản để chạy trợ lý AI.
3. Cài đủ runtime YOLO trước khi chạy nhận diện thật:

   ```powershell
   py -3.13 -m venv .venv-server
   .\.venv-server\Scripts\python.exe -m pip install -r ai_server\requirements.txt
   Push-Location ai_server
   ..\.venv-server\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000
   Pop-Location
   flutter pub get
   flutter run
   ```

Trợ lý AI là tùy chọn. YOLO không cần khóa OpenAI. Xem các tài liệu bàn giao
trợ lý và dẫn đường trong thư mục này nếu cần cấu hình thêm.

## Kiểm thử

- `flutter analyze`: không có vấn đề.
- `flutter test`: toàn bộ 46 test đã qua (44 test sẵn có và 2 test bổ sung).
- `flutter test test/device_coordination_test.dart`: 2 test bổ sung đã qua,
  kiểm tra request chồng nhau, loại kết quả cũ sau pause, resume, ngắt tiếng AI
  bằng cảnh báo và xóa ưu tiên TTS trước STT.
- `camera_pairing_test.dart`: chờ chụp ảnh hoàn tất trước khi nhường camera,
  giữ tuyến đường/TTS hoạt động và loại detection cũ khi khôi phục.
- `session_navigation_test.dart`, `assistant_test.dart`, `voice_command_router_test.dart`:
  camera lỗi, lệnh STT, xác nhận đích đến, phản hồi AI cũ và chặn tiếng AI khi cảnh báo.
- `ai_server/test_detect_endpoint.py`: test bổ sung cho thiếu ảnh, ảnh rỗng/hỏng,
  ảnh hợp lệ và lỗi inference, dùng mock detector để không tải model.
- Backend: 12 test của `test_detector`, `test_detect_endpoint`, `test_routing` đã qua
  trên `.venv-ai` (Python 3.10). Chạy lại bằng lệnh dưới từ thư mục `ai_server`:

  ```powershell
  ..\.venv-ai\Scripts\python.exe -X utf8 -B -m unittest test_detector test_detect_endpoint test_routing
  ```

Bộ test backend trợ lý có 8 lỗi trên Python 3.10 do thiếu `asyncio.timeout`;
cần Python 3.11 trở lên để kiểm tra đầy đủ. Test giải mã ảnh QR cần thêm
`opencv-python-headless`, chưa được cài trong môi trường kiểm thử này.

Kiểm thử tự động dùng mock thiết bị/inference. Chưa xác nhận trên điện thoại thật:
quyền camera/micro, STT tiếng Việt, giọng TTS, rung, background/resume và quét QR.
Chưa chạy YOLO với trọng số thật; cần cài `ultralytics` và tải model khi demo.

# Bàn giao Người 2: YOLO và nền tảng thiết bị

Nhánh local: `codex/person2-only`. Chưa commit hoặc push thay đổi thu gọn.
Nguồn đầy đủ trước khi thu gọn vẫn nằm trong các nhánh khôi phục local.

## File thuộc phạm vi

- Backend: `ai_server/detector.py`, `/detect` và `/health` trong `ai_server/main.py`.
- Detection/perception: `ai_detection_service.dart`, `obstacle_reasoning_service.dart`,
  `detection_result.dart`, `perception_frame.dart`, `session_state.dart`,
  `perception_preview.dart`, `status_panel.dart`.
- Thiết bị: `frame_source.dart`, `voice_service.dart`, `voice_command_router.dart`,
  `tts_service.dart`, `talk_button.dart` và quyền Android camera/micro/Internet.
- Điều phối: `lib/controllers/session_controller.dart`.
- `lib/main.dart` và `ai_navigation_screen.dart` chỉ là entry point/màn hình demo thiết bị;
  không triển khai `home_screen.dart`, bản đồ hay màn hình hội thoại của người khác.
- Test: reasoning, xử lý lệnh, TTS, request chồng nhau, detection cũ,
  lỗi camera/inference, QR camera lease, STT và lifecycle của màn hình thiết bị.

Các module địa lý, dẫn đường, assistant/pairing và thư viện tương ứng đã được bỏ
khỏi bản bàn giao. Không có import tới code Người 1 hoặc Người 3.

## Điểm kết nối để tích hợp

Người 1 giữ màn hình chính và dẫn đường. Người 3 giữ UI trợ lý/QR và quản lý entry point
backend chung. Họ dùng bộ điều phối thiết bị qua các API sau:

- `SessionController(onVoiceCommand: (command, text) async { ... })`:
  nhận transcript và intent đã phân loại. Thành viên phụ trách tự xử lý tìm đích,
  tuyến đường hoặc hội thoại. Bộ điều phối không tự thực hiện các hành động đó.
- `speakGuidance(text)`: tiếng hướng dẫn ưu tiên 1.
- `speakAssistant(text)`: tiếng trợ lý ưu tiên 0.
- Cảnh báo vật cản ưu tiên 3, chặn tiếng thấp hơn và không phát lời khi STT đang nghe.
  Hai hàm tiếng ngoài trả `false` khi không được nói; bên gọi tự quyết định có thử lại.
- `onTalkStart()` / `onTalkEnd()`: TTS im trước khi STT bắt đầu, chờ transcript cuối.
- Lifecycle: gọi `pause()` khi app paused/hidden và `resume()` khi trở lại.
  Pause hủy STT, ngắt TTS, đóng camera; resume chỉ tự chạy perception nếu trước pause
  đang chạy. Dừng thủ công không bị tự bật lại.
- QR: gọi `wasRunning = await suspendCameraForQr()` trước khi mở scanner.
  Chờ native scanner dispose hoàn tất, rồi gọi
  `resumeCameraAfterQr(restartPerception: wasRunning)` trong `finally`.
  Bộ điều phối chỉ quản lý quyền sử dụng camera, không giải mã QR hoặc xử lý token.
- Màn hình demo nhận callback `scanQr` tùy chọn. Scanner và pairing do Người 3 cung cấp.

Camera native được tuần tự hóa; HTTP inference không giữ camera lease.
Chỉ một request detection đang chạy. Epoch đổi sau stop/pause/QR/dispose để kết quả cũ
không phát cảnh báo hoặc được đưa lên preview.

## Kiểm tra

```powershell
flutter analyze
flutter test
.\.venv-ai\Scripts\python.exe -X utf8 -B -m unittest discover -s ai_server -p "test_*.py"
```

Test backend mock inference; chưa chạy YOLO với trọng số thật hoặc kiểm tra trên điện thoại.
Dùng `--dart-define=AI_SERVER_URL=...` để cấu hình server, không dùng `.env`.

Kết quả kiểm tra bản thu gọn: `flutter analyze` không có lỗi; 21 test Flutter và 6 test backend đều đạt.

# Chạy thử phần Người 2

1. Từ thư mục gốc, cài `ai_server/requirements.txt` vào môi trường Python của bạn.
2. Chạy `python -m uvicorn main:app --app-dir ai_server --host 0.0.0.0 --port 8000`.
3. Kiểm tra `http://127.0.0.1:8000/health` trả `{"status":"ok"}`.
4. Điện thoại và máy chạy server cùng Wi-Fi. Lấy IPv4 của máy bằng `ipconfig`.
5. Chạy `flutter run --dart-define=AI_SERVER_URL=http://<IPv4>:8000`.
6. Cấp quyền camera/micro; màn hình demo bắt đầu nhận diện và có nút Bắt đầu/Dừng.
7. Nhấn giữ nút nói để kiểm tra STT tiếng Việt. Bản độc lập chỉ nhận và phân loại lệnh;
   hành động dẫn đường/hội thoại được nối bằng callback của Người 1/3.

Kiểm tra thiết bị thật: cảnh báo tiếng Việt và rung, nhấn giữ/thả nhanh nút nói,
đưa app vào nền rồi quay lại, dừng thủ công rồi pause/resume. QR scanner do Người 3
cung cấp; chỉ mở scanner sau khi bộ điều phối nhường camera và phải dispose scanner
trước khi trả lại camera.

YOLO có thể tải trọng số ở lần chạy đầu. STT/TTS phụ thuộc engine và ngôn ngữ
đã cài trên Android. Kiểm thử tự động dùng mock, không thay cho thử trên điện thoại.

# Chạy demo dẫn đường đi bộ

## Backend

Từ thư mục dự án, dùng virtualenv Python 3.11 trong **ai_server**, không dùng `.venv` ở gốc:

```powershell
cd ai_server
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000
```

Nếu chưa có virtualenv:

```powershell
# Chạy lệnh này từ thư mục gốc dự án, trước khi cd ai_server.
py -3.11 -m venv ai_server/.venv
```

`/health` phải có `routing_profile=pedestrian`, `api_version=2`. Routing mặc định dùng Valhalla public; để tự host, đặt `$env:VALHALLA_URL='http://localhost:8002'` trước khi chạy backend. Lần đầu YOLO có thể tải `yolo11n.pt`.

## Flutter Android

```powershell
flutter pub get
flutter run --dart-define=AI_SERVER_URL=http://<IPv4-laptop>:8000
```

Nếu clone mới chưa có `.env`, chạy `Copy-Item .env.example .env` trước `flutter pub get` vì `.env` là asset của Flutter. Có thể để file rỗng khi chỉ cấu hình bằng dart-define.

Thay `<IPv4-laptop>` bằng địa chỉ IPv4 hiện tại từ `ipconfig`. Hai máy cùng mạng; cho phép Python qua firewall private network và mở `/health` từ điện thoại trước. Android emulator dùng `10.0.2.2`; `127.0.0.1` trên điện thoại là chính điện thoại.

`AI_SERVER_URL` ưu tiên `--dart-define`, rồi `.env`, cuối cùng endpoint có sẵn trong code. Backend cũ trả route ô tô sẽ bị client từ chối; triển khai backend và client v2 cùng nhau.

## Sử dụng

1. Cho phép vị trí chính xác, micro, camera. Camera lỗi vẫn có bản đồ/GPS.
2. Đợi marker GPS và vòng sai số. Mũi tên xanh chỉ **đầu điện thoại**; giữ đầu máy hướng phía trước. Bản đồ luôn hướng Bắc.
3. Nhập địa điểm và xác nhận, hoặc nhấn giữ nói “đi đến ...”, thả nút, rồi nói “xác nhận”. Nhấn giữ trên map để đặt đích thủ công.
4. Xanh lá là vệt GPS đã đi, xanh dương là phần còn lại, cam là hướng theo lối đi. Nút GPS đưa map trở về vị trí.
5. “Tôi ở đâu” đọc địa chỉ gần GPS/hướng/sai số; “nhắc lại” đọc hướng dẫn; “dừng dẫn đường” hủy đích.
6. Sau 30 giây có di chuyển, phần còn lại được tính lại. Vệt đã đi không mất. Màn hình hành trình có nút xóa vệt lưu trên thiết bị.

Kiểm tra đầy đủ và bàn giao: [docs/HANDOFF_PEDESTRIAN.md](docs/HANDOFF_PEDESTRIAN.md). Chưa có xác minh thực địa hoặc hỗ trợ dẫn đường khi khóa màn hình.

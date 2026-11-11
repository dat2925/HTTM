# Smart Navigation — dẫn đường cho người khiếm thị

App Flutter (Android) dẫn đường đi bộ bằng giọng nói, kèm cảnh báo vật cản từ camera.
Đây là bản demo học thuật, chưa được kiểm chứng an toàn ngoài thực địa.

- **Chỉ đường bằng giọng nói:** nói điểm đến, app tìm tuyến đi bộ (Valhalla) rồi đọc hướng
  theo la bàn: "Đi thẳng", "Chếch sang trái, hướng 11 giờ", "Quay sang phải, hướng 3 giờ",
  "Quay lại". Khi quay tới đúng hướng, máy rung và nói "Đúng hướng".
- **Cảnh báo vật cản:** camera gửi ảnh JPEG khoảng mỗi 900 ms lên server, YOLO nhận diện,
  app đọc cảnh báo ngắn và rung.
- **Trợ lý AI (tùy chọn):** hỏi đáp và mô tả ảnh qua OpenAI, chỉ chạy ở backend.

```
Camera -> HTTP /detect -> YOLO -> ánh xạ lớp + heuristic bbox -> cảnh báo TTS/rung
Giọng nói -> tìm địa điểm -> xác nhận -> tuyến đi bộ -> khớp GPS + la bàn -> chỉ hướng TTS
```

## Yêu cầu

- Flutter SDK, Android SDK, điện thoại Android có la bàn.
- Python 3.11 trở lên cho backend.

## 1. Chạy backend (`ai_server`)

Virtualenv nằm ở **thư mục gốc** của dự án (`.venv`).

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r ai_server\requirements.txt
cd ai_server
..\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000
```

Kiểm tra: mở `http://localhost:8000/health`, phải thấy
`{"status":"ok","routing_profile":"pedestrian","api_version":"2"}`.

Cấu hình đọc từ biến môi trường, nếu không có thì đọc `ai_server/.env`
(tạo từ `ai_server/.env.example`):

| Biến | Ý nghĩa |
|---|---|
| `YOLO_MODEL` | File model trong `ai_server/`. Mặc định `yolo11n.pt` (COCO, tự tải lần đầu). |
| `YOLO_CONFIDENCE` | Ngưỡng tin cậy, mặc định `0.35`. |
| `DETECT_MAX_BYTES` | Giới hạn ảnh tải lên `/detect`, mặc định 5 MB. |
| `NOMINATIM_CONTACT` | Liên hệ gửi kèm User-Agent khi tìm địa điểm. |
| `VALHALLA_URL` | Server định tuyến, mặc định dịch vụ Valhalla công cộng. |

### Model YOLO tự train

File trọng số không nằm trong git. Chép `best.pt` vào `ai_server/` rồi đặt tên file trong
`YOLO_MODEL`, ví dụ `YOLO_MODEL=httm_yolo11s_v2.pt`. Model có 10 lớp
(`Bang hieu`, `Cay coi`, `Cot`, `Den giao thong`, `Nguoi`, `O ga`, `Thung rac`, `Xe dap`,
`Xe hoi`, `Xe may`); server đổi chúng sang tên chuẩn (`person`, `pothole`, `pole`…) trước
khi trả về app. Lớp chưa có trong bảng ánh xạ sẽ được ghi cảnh báo vào log khi khởi động.

Server nạp sẵn model lúc khởi động, vì app chỉ chờ `/detect` tối đa 4 giây.

### Truy cập từ bên ngoài

Nếu đặt backend sau tunnel hoặc reverse proxy, cổng đích của tunnel phải trùng cổng
uvicorn. Sai cổng thì tên miền trả về 502 dù server vẫn chạy.

## 2. Cấu hình và chạy app

App cần biết địa chỉ backend qua `AI_SERVER_URL`, theo thứ tự ưu tiên:
`--dart-define`, rồi file `.env` ở thư mục gốc, cuối cùng là địa chỉ mặc định trong
[lib/config/ai_config.dart](lib/config/ai_config.dart).

```powershell
Copy-Item .env.example .env   # chỉ khi chưa có .env
flutter pub get
```

Sửa `.env`:

```
AI_SERVER_URL=http://<IPv4-của-máy-chạy-backend>:8000
```

- Điện thoại và máy chạy backend phải cùng mạng. Lấy IPv4 bằng `ipconfig`, và thử mở
  `http://<IPv4>:8000/health` bằng trình duyệt trên điện thoại trước.
- Giá trị trong `.env.example` chỉ là ví dụ. Để nguyên nó thì app sẽ không kết nối được.
- Android emulator dùng `10.0.2.2`. `127.0.0.1` trên điện thoại là chính điện thoại.
- Backend có HTTPS công khai thì đặt thẳng URL đó.

`.env` được đóng gói vào app lúc build, nên **đổi địa chỉ là phải build lại**:

```powershell
flutter build apk --release
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

Hoặc chạy trực tiếp khi phát triển: `flutter run`.

## 3. Sử dụng

1. Cho phép vị trí chính xác, micro và camera.
2. Cầm điện thoại **nghiêng như khi đọc màn hình, đầu máy chĩa về phía trước**. La bàn lấy
   theo cạnh trên của máy; dựng đứng hẳn máy lên sẽ cho hướng sai.
3. Giữ nút nói và nói điểm đến: "đi đến…", "tôi muốn đi đến…", "chỉ đường đến…",
   "dẫn đường tới…".
4. App đọc địa điểm tìm được. Nói "xác nhận" để bắt đầu, hoặc "hủy". Không trả lời trong
   30 giây thì yêu cầu tự hủy.
5. Đi theo chỉ dẫn. Cùng một chỉ dẫn lặp lại mỗi 8 giây; xoay người thì có câu mới sau
   tối đa 3 giây.

Lệnh khác: "tôi ở đâu", "nhắc lại", "cập nhật tuyến", "dừng dẫn đường".

Cảnh báo và chỉ đường không cắt ngang nhau: câu đến sau chờ câu đang đọc xong. Chỉ cảnh
báo mức cao và câu hỏi xác nhận mới được cắt ngang.

## 4. Trợ lý AI (tùy chọn)

Khóa OpenAI chỉ nằm trong `ai_server/.env`, không bao giờ đưa vào app.

```powershell
cd ai_server
..\.venv\Scripts\python.exe setup_assistant.py        # tạo khóa ký và mã ghép nối
..\.venv\Scripts\python.exe setup_assistant.py --qr   # tạo .assistant-state\pairing-qr.png
```

Các endpoint `/assistant/*` yêu cầu HTTPS. Trong app, bấm "Kết nối trợ lý" rồi quét mã QR.
QR phải được tạo trên chính máy đang chạy backend, vì nó chứa mã ghép nối của máy đó.
Giữ ảnh QR riêng tư. Chi tiết: [docs/HANDOFF_OPENAI_ASSISTANT.md](docs/HANDOFF_OPENAI_ASSISTANT.md).

## 5. Test

```powershell
flutter analyze
flutter test
cd ai_server
..\.venv\Scripts\python.exe -X utf8 -B -m unittest discover -p "test_*.py"
```

## Giới hạn

- Mức "nguy hiểm" của vật cản là heuristic theo kích thước khung hình, không phải khoảng
  cách thật. Chưa có ước lượng độ sâu hay vùng đi được.
- Bản demo chấp nhận GPS sai số tới 50 m, nên chỉ dẫn rẽ có thể sớm hoặc muộn.
- La bàn sai khi ở gần kim loại, nam châm, hoặc khi máy dựng đứng.
- Chưa dẫn đường khi khóa màn hình. Tuyến theo dữ liệu OSM chưa được chứng minh là an toàn
  cho người khiếm thị.

## Tài liệu khác

- [DEMO_SETUP.md](DEMO_SETUP.md): kịch bản demo và thao tác trên bản đồ.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): kiến trúc.
- [ai_server/README.md](ai_server/README.md): API của backend.

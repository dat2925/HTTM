# Backend nhận diện — Người 2

`detector.py` chạy YOLO và lọc vật cản; `main.py` là entry point demo chỉ có
`GET /health` và `POST /detect` (multipart field `image`).

```powershell
python -m pip install -r ai_server/requirements.txt
python -m uvicorn main:app --app-dir ai_server --host 0.0.0.0 --port 8000
python -m unittest discover -s ai_server -p "test_*.py"
```

Chạy các lệnh từ thư mục gốc dự án. Khi tích hợp, Người 3 quản lý entry point
backend chung và đăng ký `/detect` cùng các module của Người 1/3.
Bản này không có routing/geocoding hoặc các endpoint trợ lý.

Ảnh thiếu trả 422; ảnh rỗng hoặc hỏng trả 400; lỗi inference trả 500 với thông báo ổn định.
Test endpoint mock detector, không tải trọng số hoặc gọi dịch vụ ngoài.

Model mặc định `yolo11n.pt`; đổi qua `YOLO_MODEL` và `YOLO_CONFIDENCE`.
Mức nguy hiểm dựa trên diện tích bounding box, không phải khoảng cách vật lý.

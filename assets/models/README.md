# Mô hình nhận diện trên máy

Trên máy xuất mô hình, cài công cụ rồi xuất từ trọng số đã huấn luyện:

```sh
pip install "ultralytics[export-litert]"
```

```python
from ultralytics import YOLO
YOLO("best.pt").export(format="litert", nms=None, imgsz=640)
```

Sao chép file `.tflite` đã xuất thành
`assets/models/httm_yolo11n_ft20.tflite`. Không đưa trọng số vào git.
Thiếu file này, ứng dụng dùng server trong chế độ `DETECTION_MODE=auto`.

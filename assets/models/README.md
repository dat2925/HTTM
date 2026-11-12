# Mô hình nhận diện trên máy

Mọi file `.tflite` đặt trong thư mục này đều được đóng gói vào app. Chọn file app dùng
bằng `DEVICE_MODEL` trong `.env` (hoặc `--dart-define=DEVICE_MODEL=...`), rồi build lại:

| File | Mô hình |
|---|---|
| `httm_yolo11n_ft20.tflite` | Mô hình tự train 10 lớp (mặc định) |
| `yolo11n.tflite` | YOLO11n gốc, 80 lớp COCO; app chỉ dùng các lớp là vật cản |

Trọng số không nằm trong git. Thiếu file được chọn thì app dùng server khi
`DETECTION_MODE=auto`.

## Xuất file

Ultralytics chỉ xuất LiteRT trên Linux x86 và macOS (trên Windows dùng WSL hoặc Colab):

```sh
pip install "ultralytics[export-litert]"
```

```python
from ultralytics import YOLO
YOLO("best.pt").export(format="litert", nms=None, imgsz=640)      # mô hình tự train
YOLO("yolo11n.pt").export(format="litert", nms=None, imgsz=640)   # mô hình gốc
```

Chép file `.tflite` vào đây với đúng tên trong bảng trên.

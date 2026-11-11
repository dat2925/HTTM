# Thiết kế: chạy YOLO trên điện thoại

Cập nhật 11/11/2026. Trạng thái: **giai đoạn 1 đang triển khai**; giai đoạn 2–3 mới là thiết kế.
Nền tảng đích: Android. Thiết bị không có cảm biến độ sâu.

Bản 28/10 chọn `tflite_flutter` + luồng ảnh YUV + tracker ngay từ đầu. Bản này đổi thứ tự:
làm đường ngắn nhất để có cảnh báo không cần mạng trước, phần tăng tần suất để sau. Lý do
ở mục 3.

## 1. Mục tiêu và phạm vi

Giai đoạn 1 (bản này triển khai):

- Cảnh báo vật cản chạy được khi không có mạng hoặc server chết.
- Dùng model nano tự train 10 lớp (`yolo11n_ft20`), không còn model COCO.
- Giữ nguyên `DetectionResult`/`DetectedObject`, vòng chụp ảnh, hàng đợi giọng nói và
  ảnh cho trợ lý. Server `/detect` vẫn là đường dự phòng.

Để sau: luồng ảnh liên tục 5–10 Hz, lọc theo nhiều khung hình, tracker và nhãn "đang lại
gần" (mục 7). Không thuộc phạm vi: khoảng cách theo mét, vùng đi được, iOS.

## 2. Hiện trạng

`SessionController` chụp JPEG bằng `takePicture()` mỗi 900 ms rồi gửi lên `/detect`.
Server chạy model 10 lớp `yolo11s` v2, đổi tên lớp sang tên chuẩn, tính `position` và
`danger` ([detector.py](../ai_server/detector.py)). App chờ tối đa 4 giây. Mất mạng là
mất toàn bộ cảnh báo vật cản.

## 3. Quyết định chính

| Vấn đề | Chọn | Lý do |
|---|---|---|
| Runtime | `ultralytics_yolo` 0.7.2, gọi `YOLO.predict(bytes)` | Bản mới 08/11/2026, chạy LiteRT 2.x, tự thử GPU rồi lùi về CPU, tự đọc tên lớp trong model, làm sẵn tiền xử lý và NMS ở native. `minSdk` vẫn 24. `tflite_flutter` phát hành lần cuối 10/2025 và buộc phải tự viết tiền/hậu xử lý bằng Dart |
| Nguồn ảnh | Giữ `takePicture()` | Camera vẫn do app giữ (preview, QR, ảnh trợ lý không đổi). `predict` nhận thẳng bytes JPEG. Không dùng `YOLOView` vì nó chiếm camera |
| Model | `yolo11n_ft20` xuất LiteRT, `imgsz=640`, `nms=None` | Model train ở 640; cột và cây vốn đã khó bắt, giảm xuống 320 sẽ sót thêm. Ở nhịp 1–2 Hz thì 640 vẫn kịp |
| Luật vị trí/nguy hiểm | Viết lại bằng Dart, kiểm bằng fixture dùng chung với Python | Hai đường phải cho cùng kết quả với cùng một hộp |
| Chọn đường | `DETECTION_MODE`: `auto` (mặc định), `device`, `server` | `auto`: model nạp được thì chạy trên máy, không thì dùng server |
| File model | `assets/models/*.tflite`, không đưa vào git | Giữ quy ước trọng số không nằm trong git. Thiếu file thì `auto` tự dùng server |

Cái giá của lựa chọn này: mỗi khung hình vẫn phải chụp và giải mã JPEG, nên nhịp nhận diện
dừng ở khoảng 2 Hz. Đổi lại không phải viết và kiểm thử phần chuyển YUV, letterbox, giải mã
tensor và NMS.

Giấy phép: `ultralytics_yolo` và trọng số YOLO11 là AGPL-3.0, giống server. Đủ cho đồ án.

## 4. Kiến trúc giai đoạn 1

```
takePicture (JPEG) ─► HybridDetectionService
                        ├─ máy:    dựng ảnh đúng chiều ─► YOLO.predict ─► obstacle_rules ─► DetectionResult
                        └─ server: POST /detect ───────────────────────────────────────► DetectionResult
                                                           SessionController (không đổi luồng xử lý)
```

- `lib/services/obstacle_rules.dart`: bảng đổi tên lớp, `positionFor`, `dangerFor`, giống
  `detector.py`.
- `lib/services/on_device_detection_service.dart`: nạp model, gọi `predict` với
  `conf=0.35`, `iou=0.45`, đổi kết quả sang `DetectionResult`. Plugin được bọc sau một
  interface nhỏ để test không cần native.
- `lib/services/detection_backend.dart`: interface chung và `HybridDetectionService`.
- `SessionController` nhận interface thay cho `AiDetectionService`; nhịp chụp 500 ms khi
  chạy trên máy, 900 ms khi dùng server.

### Chiều ảnh

`takePicture()` có thể ghi ảnh nằm ngang kèm thẻ EXIF. Plugin giải mã bằng
`BitmapFactory`, bỏ qua EXIF, nên model sẽ nhìn ảnh xoay ngang và trái/phải bị sai. Trước
khi `predict`, app đọc thẻ EXIF trong header JPEG; nếu ảnh không thẳng thì dựng lại bằng
codec của Flutter (có áp EXIF) rồi mới đưa cho plugin. Ảnh đã thẳng thì đi thẳng, không
tốn thêm gì.

## 5. Khi lỗi

- Model không nạp được, thiếu file hoặc lớp trong model không khớp bảng tên: không chạy
  trên máy. `auto` chuyển sang server; `device` báo mất nhận diện như hiện tại.
- Ba lần `predict` lỗi liên tiếp: `auto` chuyển sang server cho hết phiên.
- Không bao giờ nói "an toàn" khi không có đối tượng. Các câu báo mất nhận diện giữ nguyên.

## 6. Kiểm thử

- Fixture `test/fixtures/detection_rules_parity.json`: Dart và `ai_server/test_detector.py`
  đọc cùng file, kết quả `position`/`danger`/tên lớp phải trùng.
- Unit: đổi kết quả plugin sang `DetectionResult`, đọc EXIF, chọn đường và lùi về server.
- Toàn bộ test hiện có phải đạt.
- Trên máy thật (chưa làm được bằng test tự động): thời gian mỗi khung hình, GPU hay CPU,
  trái/phải có đúng không, nóng máy sau 30 phút.

Chưa có số đo độ chính xác của bản LiteRT trên tập test; cần chạy lại `val` với file
`.tflite` trong Colab để so với bản `.pt` (mAP50 0,874).

## 7. Giai đoạn sau

| Giai đoạn | Nội dung | Điều kiện làm |
|---|---|---|
| 2. Luồng ảnh | `startImageStream` thay `takePicture`, frame mới nhất thắng, trần 10 Hz; cảnh báo theo k-trên-n khung hình; đổi `safeCyclesRequired` sang tính theo thời gian | Số đo giai đoạn 1 cho thấy chụp ảnh là nút thắt |
| 3. "Đang lại gần" | Tracker IoU, hồi quy `ln(chiều cao hộp)` theo thời gian để ước lượng thời gian tới chạm; chỉ nói "đang lớn dần", không nói mét hay giây | Có luồng ảnh ổn định |
| 4. Thực địa | Khu vực kín, có người đi kèm; đo trễ, báo nhầm, bỏ sót, pin, nhiệt | Sau giai đoạn 2 |

## 8. Rủi ro

- GPU delegate không nhận graph trên một số máy; plugin tự lùi về CPU, khi đó 640 có thể
  mất vài trăm ms mỗi ảnh. Nếu quá chậm thì xuất lại ở 320 và chấp nhận sót vật nhỏ.
- Model nano sót cột, cây và đèn giao thông nhiều hơn v2 trên server (recall 0,43 / 0,56 /
  0,75 so với 0,51 / 0,74 / 0,88). Chạy trên máy đổi độ chính xác lấy việc không cần mạng.
- APK tăng theo kích thước model và thư viện LiteRT.

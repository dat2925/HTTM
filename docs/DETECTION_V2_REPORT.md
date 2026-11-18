# Detection V2 — báo cáo theo phase

Ngày 18/11/2026. Không có kết quả thực nghiệm về độ chính xác hoặc tốc độ trên điện thoại.

## Khảo sát và baseline (trước sửa code)

Đã đọc README, ARCHITECTURE, DESIGN_ON_DEVICE_YOLO và rà soát SessionController,
FrameSource, HybridDetectionService, OnDeviceDetector, ObstacleReasoningService,
SituationEngine, detector.py. Camera dùng takePicture JPEG, timer 500 ms device /
900 ms server, bỏ tick khi bận. Session epoch loại kết quả sau stop/nhường camera;
SituationEngine TTL 5 giây; cảnh báo đã có cooldown theo class/vùng/mức ưu tiên.

Model mặc định device: `assets/models/httm_yolo11n_ft20.tflite`, đổi qua DEVICE_MODEL;
server: YOLO_MODEL, mặc định `yolo11n.pt`, CPU. Không tìm thấy trọng số trong checkout.
Chỉ đọc whitelist cấu hình detection, không dump .env hoặc secret. Cấu hình hiệu lực
trong checkout kiểm cuối: client `auto` + `httm_yolo11n_ft20.tflite`; server chọn
`yolo11n.pt`, confidence .35, không override IoU/imgsz; file weights không tồn tại.
Vì vậy chưa có model nào được xác nhận nạp thành công ở đây; auto sẽ thử server.
Model thực sự trên thiết bị/server đang triển khai
chưa xác minh; overlay dùng metadata kết quả, không coi tên mặc định là model đã nạp.
Auto thử device, lỗi prepare thì server; ba lỗi predict liên tiếp chuyển server
cho request **tiếp theo**, request gây lỗi vẫn báo lỗi. Device-only không fallback.
Plugin GPU được yêu cầu nhưng delegate thực tế chưa có telemetry, ghi unverified.

Baseline: flutter analyze PASS (36.6 s); flutter test PASS 212 tests (27 s).
Python mặc định 3.9: 19 tests, 1 failure, 6 errors, 1 skipped, do thiếu dependency,
Python <3.11 và test phụ thuộc yolo11n.pt có trên đĩa. Đã tạo .venv Python 3.13,
cài dependency phục vụ tests trong giới hạn requirements (chưa cài ultralytics/torch
vì không có weights). Sửa riêng test path dùng file tạm, không tạo model giả.
Thay đổi có sẵn `.env.example` bị xóa và pubspec.lock đã sửa được giữ lại.

## Phase 1 — debug và benchmark

Triển khai:

- DetectionResult metadata tùy chọn; `/detect?diagnostics=true` trả model basename,
  runtime CPU, thời gian worker detector; `/detect` mặc định giữ response cũ.
- PerceptionFrame ghi timestamp, backend/model/runtime, capture/detect/total latency.
  FPS dựa khoảng cách giữa các kết quả hoàn tất; frame đầu ghi 0 (chưa đủ mẫu).
- Overlay hiện metadata thực tế, confidence/vùng trên bbox. `DETECTION_DEBUG=true`
  qua dart-define bật JSON log `DetectionV2`; không ghi ảnh/GPS, không lưu lịch sử vô hạn.
- `ai_server/detection_benchmark.py`: thu server predictions và chấm JSONL, IoU
  one-to-one theo class, duplicate = FP, sai class = FP + FN; precision/recall
  micro và từng class, latency p50/p95. Thiếu frame hoặc sai kích thước là lỗi.
- `lib/detection_benchmark_main.dart`: entry point riêng chạy cùng tập ảnh trên
  device/server. Không gọi GPS/TTS/navigation. Không đổi model production.

Kiểm thử gate trước phase tiếp: analyze PASS; Flutter 213 PASS; Python 72 tests
OK, 1 skipped (test trọng số thật). Unit/widget dùng fixture kiểm logic, không phải
benchmark thực nghiệm. Chưa có dataset/model/điện thoại: so sánh precision, recall,
latency device/server **chưa đo**, không kết luận cải thiện.

Định nghĩa timing: device predict bao gồm platform channel và native preprocessing/
inference/postprocessing; server inference_ms gồm threadpool/lock wait + detector.
Không phải GPU kernel time. Total trong phiên gồm capture + cache ảnh + detect,
không gồm TTS; benchmark ảnh loại capture. So sánh cùng định nghĩa và phần cứng.

### Chạy benchmark khi có dữ liệu

Mỗi dòng truth.jsonl (nhãn canonical, bbox pixel ảnh đã dựng đúng chiều):

```json
{"frame_id":"clip01:000123","image":"frames/000123.jpg","image_width":640,"image_height":480,"objects":[{"class_name":"pole","box":[200,50,240,430]}]}
```

Ví dụ trên chỉ là schema, không phải dữ liệu thực nghiệm. Video: trích frame cố định
theo timestamp rồi gán nhãn; dùng cùng frame IDs và pixels cho hai backend. Giữ tập
validation tách train, ghi ánh sáng, vật nhỏ, che khuất, cảnh không có đối tượng;
báo latency cold/warm riêng, pin/nhiệt/phần cứng và số mẫu. Metric hiện là P/R tại
IoU đã chọn, không phải COCO mAP hoặc đánh giá an toàn thực địa.

```powershell
.venv/Scripts/python.exe ai_server/detection_benchmark.py server dataset/truth.jsonl http://localhost:8000 server.jsonl
.venv/Scripts/python.exe ai_server/detection_benchmark.py evaluate dataset/truth.jsonl server.jsonl
flutter run -t lib/detection_benchmark_main.dart --dart-define=BENCHMARK_MANIFEST=/app-readable/dataset/truth.jsonl --dart-define=BENCHMARK_BACKEND=device
```

Chép dataset vào thư mục app đọc được bằng adb/run-as cho debug build; kéo output
JSONL về rồi chấm bằng cùng lệnh evaluate. Chạy YOLO11n/YOLO11s custom bằng
DEVICE_MODEL/YOLO_MODEL, lưu output riêng. Warm-up device load ngoài phép đo;
lần predict đầu vẫn cold. Không dùng log live camera để so trực tiếp ảnh benchmark
vì timestamp/frame IDs không tự khớp. Không đặt secret trong dataset/output.

File phase 1: models/detection_result.dart, models/perception_frame.dart,
controllers/session_controller.dart, services/{ai_detection_service,on_device_detection_service}.dart,
widgets/perception_preview.dart, lib/detection_benchmark_main.dart,
ai_server/{main,detection_benchmark,test_detection_benchmark,test_detector,test_detect_endpoint}.py,
test/perception_preview_test.dart và báo cáo này.

## Các phase tiếp theo

### Phase 2 — camera pipeline

`--dart-define=CAMERA_STREAM=true` bật thử nghiệm trên camera sau Android;
mặc định giữ snapshot. FrameSource sở hữu duy nhất camera, giữ một CameraImage
mới nhất, thay frame trước, chỉ encode khi consumer lấy; không FIFO, không encode
mọi callback. Giữ nhịp trần 10 Hz device stream; server giữ 900 ms. Assistant lấy
JPEG từ cùng nguồn; QR vẫn dispose/khôi phục camera qua khóa/epoch hiện có.

`camera_frame_adapter.dart` copy planes, chuyển YUV420 3-plane (row/pixel stride)
hoặc BGRA sang RGB, xoay theo sensor/device orientation, encode JPEG quality 90
bằng package image trong compute isolate. Không crop/resize trước YOLO, runtime
tự letterbox. Không hỗ trợ raw NV21 1-plane; format không hỗ trợ báo lỗi, không
truyền nhầm raw bytes. Thêm dependency image 4.5.4, resolver hạ xml 7.0.1 xuống
6.6.1 theo ràng buộc image; giữ những thay đổi lock trước phiên.

Preview và overlay dùng cùng vùng AspectRatio contain, không kéo dãn bbox theo
hai trục độc lập trên cả màn hình. Cần kiểm chứng crop/FOV preview so capture,
đặc biệt khi quay thiết bị; cùng aspect ratio không chứng minh cùng hình học.
Server áp EXIF transpose trước inference để hai đường cùng ảnh dựng thẳng.
Timestamp stream lấy khi callback nhận ảnh (chưa phải sensor hardware timestamp).
Frame >1 s không dùng; hết generation hoặc conversion deadline không tạo file.
Session giữ single-flight đến khi Future native kết thúc kể cả Dart đã timeout,
không tiếp tục xếp việc lên model đang treo. Navigation vẫn độc lập.

Gate: Flutter 216 PASS; Python 73 OK (1 skip), build APK debug PASS (229.2 s).
Analyze PASS sau sửa lint. Thử converter/worker và regression camera QR,
assistant/navigation là tự động; stream thật, màu BT.601, mirror, FOV, pin/nhiệt,
10 Hz và delegate chưa xác minh. Không bật stream mặc định hoặc tuyên bố nhanh hơn.

Nguồn đã đối chiếu: source cục bộ ultralytics_yolo 0.7.2 YOLOPlugin.kt
predictSingleImage dùng BitmapFactory.decodeByteArray (ảnh encoded); camera API
[startImageStream](https://pub.dev/documentation/camera/latest/camera/CameraController/startImageStream.html)
có cơ chế drop frame; [encodeJpg](https://pub.dev/documentation/image/latest/image/encodeJpg.html).
Plugin predictSingleImage thực hiện đồng bộ trên platform handler Android; compute
loại CPU conversion khỏi UI isolate Dart nhưng không chứng minh native UI không
jank. Native worker bridge cần thiết nếu đo trên máy xác nhận nút thắt này; chưa
có bridge được kiểm chứng để khẳng định thay plugin an toàn.

Files: services/{frame_source,camera_frame_adapter}.dart, session_controller.dart,
perception_preview.dart, ai_server/main.py, pubspec.yaml/lock,
test/camera_frame_adapter_test.dart, test/device_coordination_test.dart,
ai_server/test_detect_endpoint.py.

### Phase 3 — cấu hình model

Không đổi model/threshold mặc định khi chưa benchmark. DEVICE_MODEL đã chọn
asset theo device, YOLO_MODEL chọn server độc lập. Bổ sung DEVICE_CONFIDENCE,
DEVICE_IOU (dart-define ưu tiên .env, invalid dùng default .35/.45), snapshot
cấu hình một lần khi tạo detector. Server thêm YOLO_IOU và YOLO_IMGSZ tùy chọn,
reject giá trị không hợp lệ khi khởi tạo. Khi không cấu hình, không truyền hai
tham số này để giữ default của phiên bản runtime/model thực tế (điều chỉnh sau
review tích hợp, không giả định default NMS .7 trên mọi phiên bản).
Không thêm threshold từng class vì chưa có validation để chọn chúng.

Ma trận cần chạy bằng harness phase 1: model hiện có n-ft20 LiteRT / s-v2 PT,
YOLO11n custom / YOLO11s custom xuất cùng imgsz640, cùng split, cùng ánh sáng và
frame IDs, ghi export/quantization/delegate/version/model hash. Đo P/R từng class
(nhất là cột/cây/ổ gà), confusion, cold/warm latency p50/p95 trước chọn mặc định.
Chưa có weights/dataset nên cả ma trận **chưa chạy**; không có kết luận tăng recall.

Gate: analyze PASS, Flutter 217 PASS, Python 74 OK (1 skip). Files:
config/ai_config.dart, services/on_device_detection_service.dart, ai_server/detector.py,
test/device_model_config_test.dart, ai_server/test_detector.py.

### Phase 4 — temporal tracking

ObjectTracker class-aware IoU >=.25, one-to-one, ID không tái sử dụng trong phiên,
timestamp đầu/cuối, consecutive hits và biến thiên ln(chiều cao bbox)/giây.
Chỉ xuất object quan sát hiện tại; một frame mất dấu phá xác nhận liên tiếp.
Hai frame liên tiếp mới cho cảnh báo thường; high bỏ qua chờ xác nhận ngay frame
đầu. Detection gốc và metadata vẫn có trong overlay, không coi pending là cảnh trống.
TTL 5 s; reject timestamp cũ/tương lai/ngược thứ tự. Reset khi stop/QR/lỗi nguồn,
model/backend/orientation/kích thước đổi. Không nhận dạng lại xuyên che khuất,
không suy vận tốc/khoảng cách thật, không khẳng định đang tiến gần từ bbox growth.

Gate: analyze PASS, Flutter 220 PASS (bao gồm jitter, missed frame, class/model/
geometry reset, stale/future/order, matching một-một và warning khẩn cấp). Python
không đổi từ gate 3. Files: object_tracker.dart, detection_result.dart,
perception_frame.dart, session_controller.dart, perception_preview.dart,
test/object_tracker_test.dart. Ngưỡng IoU/two-frame/TTL là engineering defaults,
chưa được chọn bằng validation thực địa.

### Phase 5 — visual risk assessment

RiskAssessmentService tách policy khỏi inference: chỉ dùng evidence còn mới,
confidence >=.35, ổn định hoặc high tức thì. Vị trí/lớp/confidence/stability và
biến thiên bbox chỉ xếp ưu tiên quan sát; high và center vẫn chi phối. Không đổi
heuristic danger legacy để giữ API, không suy depth từ diện tích hoặc bbox growth.
Reasoning nhận hàm priority tùy chọn, API cũ vẫn hoạt động. Bỏ từ “ngay” khỏi
cảnh báo high, giữ đề nghị dừng kiểm tra, không chỉ hướng né khi chưa biết lối đi.

Memory TTL 12 s theo track và semantic class/vùng/mức hạn chế cảnh báo A-B-A hoặc
ID jitter; high mới ở giữa có thể ngắt ngay, không chờ cooldown cảnh báo thường.
Mất detection cần 2 s evidence trống trước đổi thông báo, không đếm 3 frame khi
stream tăng tốc. Không có detection vẫn nói chưa xác định được lối đi. Engineering
defaults về priority/confidence/2 s chưa được validation an toàn thực địa.

Gate: analyze PASS; Flutter 223 PASS. Python không đổi từ gate 3. Files:
risk_assessment_service.dart, obstacle_reasoning_service.dart, session_controller.dart,
test/risk_assessment_service_test.dart, test/destination_lifecycle_test.dart.

### Phase 6 — tích hợp và kiểm tra cuối

- Test tích hợp trong process: camera → detection → tracker → risk → TTS,
  nhiễu một frame, high ở frame đầu, cooldown và QR reset ID, GPS không dừng.
  Test dùng fake hardware, **không** phải instrumented test trên Android.
- Widget tự hết hạn bbox sau 5 s dù không có frame mới; hiện trạng thái dữ liệu cũ.
- Device detector chống gọi chồng và chờ inference đang chạy trước dispose;
  stream format không hỗ trợ quay về snapshot. Không sửa native plugin.
- Phát hiện lỗi màu server: RGB ndarray trước đó đi qua API coi NumPy là BGR.
  Truyền PIL RGB đúng contract, test màu đỏ bảo vệ regression. Tham chiếu
  [Ultralytics input sources](https://docs.ultralytics.com/modes/predict/#inference-sources).
  Đây là sửa contract tiền xử lý; chưa đo tác động tới precision/recall.
- YOLO_IOU/YOLO_IMGSZ không cấu hình thì bỏ qua kwargs, giữ default runtime/model.
  Không khẳng định default NMS giống nhau giữa mọi bản Ultralytics.

Kết quả cuối:

| Kiểm tra | Kết quả thực chạy |
|---|---|
| flutter analyze | PASS, no issues, 2.8 s |
| flutter test --reporter expanded | PASS, 226 tests, 14 s |
| .venv Python3.13 unittest discover ai_server | OK, 76 tests, 1 skipped (không có weights thật) |
| flutter build apk --debug | PASS, 32.6 s, build/app/outputs/flutter-apk/app-debug.apk |
| git diff --check | PASS |

APK cuối là app chính dùng snapshot mặc định, không phải benchmark entry point.
Build có warning plugin flutter_tts/ultralytics_yolo về Kotlin Gradle Plugin;
warning không làm thất bại build. Chưa kiểm build release/iOS.

Files phase 6: widgets/perception_preview.dart, services/{frame_source,
on_device_detection_service}.dart, detection_benchmark_main.dart,
ai_server/{detector,detection_benchmark,test_detector}.py,
test/{detection_v2_integration,perception_preview,on_device_detection}_test.dart,
DETECTION_V2_REPORT.md và DETECTION_V2_PHASE_GATES.md.

## Phần còn thiếu và điều kiện xác nhận

1. Chưa có weights device/server trong checkout, chưa có dataset gán nhãn. Chưa
   chạy inference model thật, đánh giá n/s custom, confusion matrix, class-specific
   thresholds hoặc so sánh precision/recall/latency thực nghiệm. Harness đã sẵn sàng;
   model/config production không thay khi chưa có số liệu.
   `/health` hiện chỉ chứng minh dịch vụ HTTP hoạt động, không chứng minh weights
   đã nạp; cần kiểm `/detect` thực khi bàn giao model. .venv hiện phục vụ tests,
   muốn chạy model thật phải cài đủ requirements (ultralytics/torch).
2. Chưa có điện thoại/emulator kết nối để kiểm instrumented flow. Stream opt-in
   chưa kiểm orientation/màu/FOV trên camera thật, chuyển QR, ảnh assistant, pin,
   nhiệt và sustained FPS. Handoff thử nghiệm phải có người đi kèm, khu vực kiểm soát.
3. Native predictSingleImage có thể block platform UI thread. Dart compute chỉ
   xử lý conversion ngoài UI isolate. Chưa có native worker bridge được đo/kiểm
   chứng; không tuyên bố hết jank hoặc đạt 10 FPS (10 Hz chỉ là trần scheduling).
4. Tracker không phải re-identification; IoU mất dấu khi occlusion/chuyển động
   nhanh. Cần đo false alerts/misses/urgent latency và điều chỉnh TTL/two-frame,
   cooldown bằng video có nhãn temporal trước dùng thực địa.
5. Không đo mét, free space hoặc tuyến an toàn; mất detection không chứng minh
   không có vật cản. GPS/navigation/assistant và API detection cũ được regression
   test; đây vẫn là hệ thống demo, chưa được xác nhận an toàn cho đi lại độc lập.

Không ghi đè .env hoặc secret; không push/merge. Các phase được thực hiện lần lượt
với gate kiểm thử và báo cáo trước khi sang phase sau; toàn bộ thay đổi để review
trong working tree, chưa tạo commit. Không có số đo benchmark giả lập được gắn
nhãn là thực nghiệm.

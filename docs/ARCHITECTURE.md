# Kiến trúc hệ thống dẫn đường thông minh cho người khiếm thị

Tài liệu này tóm tắt kiến trúc mục tiêu của đề tài (dựa trên bản mô tả đầy đủ đã
thống nhất) và đối chiếu với những gì thực sự đã có trong repo hiện tại, để làm
rõ phần nào là **thật**, phần nào là **heuristic demo tạm thời**, và phần nào
**chưa tồn tại**. Phần cuối là kế hoạch xây dựng theo giai đoạn cho các phần
còn thiếu.

## 1. Bài toán và ý tưởng cốt lõi

Hệ thống giải hai bài toán chạy song song, hợp nhất tại một bộ điều phối:

- **Dẫn đường** — người dùng cần đi đâu, hướng nào, khi nào rẽ (GPS + bản đồ +
  routing + waypoint).
- **Nhận thức môi trường** — phía trước có đi được không, có vật cản gì
  (camera + depth + YOLO + walkable-area).

Giao tiếp với người dùng là **voice-first + haptic**: nhập điểm đến bằng
giọng nói (STT), phản hồi bằng câu lệnh ngắn (TTS) và rung cho tình huống khẩn
cấp. Không có tương tác chạm/nhìn màn hình trên luồng chính.

## 2. Kiến trúc mục tiêu (tổng thể)

```
                 NGƯỜI DÙNG
                     │  "Đi đến ..."
                     ▼
              Speech-to-Text ──────► Geocoding (tìm địa điểm → tọa độ)
                     │
                     ▼
              Route Planning (OSRM/GraphHopper trên server, dữ liệu OSM)
                     │
                     ▼
                 Waypoint list
                     │
      ┌──────────────┴───────────────┐
      ▼                              ▼
  GPS Positioning              Camera + AI (Environmental AI)
  (vị trí hiện tại)             Depth → Walkable Area → YOLO → Obstacle
      │                              │
      ▼                              ▼
  Route Following               Obstacle Reasoner
  (đúng hướng / sắp rẽ /             │
   lệch tuyến)                      │
      └──────────────┬───────────────┘
                      ▼
              Quyết định hành động
        (tiếp tục waypoint | cảnh báo/né | re-route)
                      │
                ┌─────┴─────┐
                ▼           ▼
               TTS        Haptic
```

Hai luồng dữ liệu độc lập (route vs. perception) được hợp nhất tại một
**Navigation/Obstacle Reasoner** duy nhất — route cung cấp *mục tiêu*,
perception quyết định *có an toàn để thực hiện mục tiêu đó không*.

## 3. Ngăn xếp công nghệ mục tiêu

| Nhóm | Công nghệ | Vai trò |
|---|---|---|
| Mobile | Flutter | Ứng dụng client |
| Camera | `camera` plugin | Thu hình |
| Depth | MiDaS Small / Depth Anything V2 Small | Ước lượng độ sâu |
| Detection | YOLO (hiện: `yolo11n.pt` qua `ai_server`; mục tiêu: YOLO26n) | Nhận dạng vật cản |
| Walkable area | Gradient + Normal Vector trên Depth Map | Vùng đi được |
| Vị trí | GPS (`geolocator`) | Vị trí hiện tại |
| Bản đồ | OpenStreetMap | Dữ liệu đường/vỉa hè |
| Routing | OSRM / GraphHopper | Tính tuyến đường |
| Voice input | `speech_to_text` | Nhập điểm đến |
| Voice output | `flutter_tts` | Hướng dẫn |
| Haptic | `HapticFeedback` / `vibration` | Cảnh báo khẩn |
| Giao tiếp | HTTP (nay) / WebSocket (khi cần real-time hai chiều) | App ↔ server |
| On-device (tương lai) | TensorFlow Lite (INT8) | Suy luận offline |

## 4. Trạng thái hiện tại trong repo — cái gì thật, cái gì là stub

### 4.1. Đã hoạt động thật

| Thành phần | File | Ghi chú |
|---|---|---|
| Camera capture dùng chung 1 stream | [lib/services/frame_source.dart](../lib/services/frame_source.dart) | Không mở 2 stream camera |
| Object Detection (YOLO thật, chạy trên server) | [ai_server/detector.py](../ai_server/detector.py), [lib/services/ai_detection_service.dart](../lib/services/ai_detection_service.dart) | `yolo11n.pt`, lọc theo `OBSTACLE_CLASSES` |
| Spatial reasoning trái/giữa/phải + chọn cảnh báo ưu tiên | [lib/services/obstacle_reasoning_service.dart](../lib/services/obstacle_reasoning_service.dart) | Đúng thuật toán #7 (Spatial Reasoning) ở mức object, chưa ở mức walkable-area |
| Temporal debouncing cảnh báo (cooldown 3s + safe-cycle) | [lib/controllers/session_controller.dart](../lib/controllers/session_controller.dart) | Thuật toán #10, đơn giản (cooldown cố định, chưa theo mức nguy hiểm biến thiên) |
| TTS + Haptic theo mức nguy hiểm | [lib/services/tts_service.dart](../lib/services/tts_service.dart), `session_controller.dart` | Rung mạnh/vừa theo `DangerLevel` |
| GPS Positioning thật | [lib/services/route_service.dart](../lib/services/route_service.dart) | `Geolocator.getPositionStream` |
| Speech-to-Text thật (ghi nhận văn bản) | [lib/services/voice_service.dart](../lib/services/voice_service.dart) | Trả text; đã nối sang geocoding (xem Giai đoạn A) |
| Cấu hình qua `.env` | [lib/config/ai_config.dart](../lib/config/ai_config.dart), `pubspec.yaml` | `flutter_dotenv` |
| Geocoding thật (giọng nói → tọa độ) | [ai_server/geocoder.py](../ai_server/geocoder.py) (`/geocode`, proxy Nominatim), [lib/services/geocoding_service.dart](../lib/services/geocoding_service.dart), [lib/models/placemark.dart](../lib/models/placemark.dart) | `SessionController.onTalkEnd` tách tiền tố ý định ("đi đến", "dẫn tôi tới", ...) rồi geocode và gọi `RouteService.setDestination` |

### 4.2. Heuristic demo — có thật một phần, chưa đúng bản chất kiến trúc

| Thành phần | File | Giới hạn hiện tại |
|---|---|---|
| "Depth"/mức nguy hiểm | [ai_server/detector.py](../ai_server/detector.py) `danger_for()` | Suy ra từ **diện tích bounding box**, không phải Depth Map thật (không có Monocular Depth Estimation) |
| "Route" | `GeolocatorRouteService` trong [route_service.dart](../lib/services/route_service.dart) | Chỉ so bearing GPS tới **1 tọa độ đích cố định** (`AiConfig.demoDestinationLat/Lng`), suy ra "đi thẳng/rẽ trái/rẽ phải" — không có route/waypoint/OSRM thật, không có turn-by-turn |
| Voice → điểm đến | `voice_service.dart` + `SessionController.onTalkEnd` | Hiển thị text nhận dạng được ở dòng phụ, **không** geocode, **không** đặt làm đích cho `RouteService` |

### 4.3. Chưa tồn tại

- Route Planning thật (OSRM/GraphHopper + dữ liệu OSM), Waypoint list: không có.
- Route Following (so sánh vị trí hiện tại với waypoint → "đúng hướng/sắp rẽ/đã đến/lệch tuyến"): không có — hiện chỉ có duy nhất "đi thẳng/rẽ trái/rẽ phải" tới 1 điểm.
- Monocular Depth Estimation (MiDaS/Depth Anything V2 Small) + Depth Map: không có.
- Walkable Area Detection từ gradient/normal vector: không có — mức nguy hiểm hiện suy từ diện tích box.
- Kết hợp Route ↔ Obstacle Reasoner để **chủ động đổi hành vi route** (ví dụ: route bảo đi thẳng nhưng camera thấy chắn hết vỉa hè → gợi ý né trái/phải): hiện `SessionController` chỉ **hiển thị song song** hai dòng "Route: ... · Camera: ..." chứ chưa có logic quyết định.
- Re-routing (phát hiện lệch tuyến hoặc route không còn khả thi → tính lại route hoặc né cục bộ): không có.
- Backend routing/geocoding trên `ai_server` (hiện `ai_server` chỉ có `/health` và `/detect`): không có.
- TensorFlow Lite / on-device inference: không có (mọi suy luận AI đang qua HTTP tới `ai_server`).

## 5. Kế hoạch xây dựng các phần còn thiếu

Thứ tự ưu tiên theo giá trị demo/tốt nghiệp: từ "nói ra được điểm đến và có
route thật" → "route theo waypoint thật" → "kết hợp route với vật cản" →
"depth/walkable-area thật" → "re-routing" → "on-device". Mỗi giai đoạn giữ
nguyên các phần đã có, chỉ thay thế heuristic bằng thành phần thật.

### Giai đoạn A — Geocoding: giọng nói → tọa độ đích thật ✅ Đã triển khai
- `ai_server/geocoder.py` + endpoint `GET /geocode?q=...` trong
  [ai_server/main.py](../ai_server/main.py): proxy Nominatim OSM (đặt
  `User-Agent` đúng usage policy), trả `{success, lat, lng, display_name}`.
  Chưa có cache/rate-limit — cần thêm nếu demo gọi nhiều lần liên tục
  (Nominatim public giới hạn ~1 req/s).
- [lib/services/geocoding_service.dart](../lib/services/geocoding_service.dart) +
  [lib/models/placemark.dart](../lib/models/placemark.dart): gọi `/geocode`,
  trả `Placemark {lat, lng, displayName}`.
- `RouteService`/`GeolocatorRouteService` trong
  [lib/services/route_service.dart](../lib/services/route_service.dart) có
  thêm `void setDestination(lat, lng)`.
- `SessionController.onTalkEnd` ([lib/controllers/session_controller.dart](../lib/controllers/session_controller.dart)):
  tách tiền tố ý định ("đi đến", "dẫn tôi tới", "đưa tôi đến", ...) khỏi câu
  nói được; nếu khớp, geocode phần còn lại → `RouteService.setDestination` →
  TTS xác nhận `"Đang tìm đường đến ..."`; nếu không tìm thấy địa điểm, TTS
  đọc lý do lỗi.
- Còn thiếu để hoàn chỉnh: nhận diện ý định bằng NLU thật thay cho so khớp
  tiền tố cứng; xác nhận lại địa điểm với người dùng trước khi đặt làm đích
  (hiện đặt đích ngay khi geocode thành công).

### Giai đoạn B — Route Planning + Waypoint thật (thay `GeolocatorRouteService`)
- Thêm endpoint `/route?from=&to=` trên `ai_server`, proxy tới OSRM (tự host
  bằng Docker + dữ liệu OSM khu vực demo, hoặc dùng OSRM demo server công khai
  cho giai đoạn phát triển).
- `lib/models/waypoint.dart`: `{lat, lng, distanceMeters, instructionText}`.
- `lib/services/route_service.dart`: thêm `OsrmRouteService implements
  RouteService` — gọi `/route`, parse thành `List<Waypoint>`, giữ
  `GeolocatorRouteService` cũ lại làm fallback/demo khi không có mạng.
- **Route Following** (thuật toán #8): thêm `RouteFollower` so vị trí GPS
  hiện tại với waypoint tiếp theo → trạng thái `onTrack / approachingTurn /
  arrivedWaypoint / offRoute`. Đây là phần thay cho khối "so bearing tới 1
  điểm" hiện tại.
- Tiêu chí xong: đặt điểm đến thật → nghe hướng dẫn theo từng waypoint, không
  phải chỉ 1 hướng cố định.

### Giai đoạn C — Kết hợp Route và Obstacle Reasoner (Decision Fusion)
- Trong `SessionController`, thay việc chỉ nối 2 dòng text bằng một hàm quyết
  định: nếu `ObstacleReasoningService` báo nguy hiểm ở đúng hướng route đang
  yêu cầu → tạm ngắt câu route, phát cảnh báo vật cản trước, sau đó nếu
  perception cho biết bên trái/phải trống → gợi ý né trước khi tiếp tục đọc
  waypoint.
- Đây là chỗ hiện đã có khung sườn (`_processResult` gộp `routeText` +
  `warning`), chỉ cần nâng cấp từ "hiển thị song song" lên "logic điều
  hướng ưu tiên".
- Tiêu chí xong: mô phỏng vật cản chắn hướng route → nghe cảnh báo trước khi
  nghe tiếp hướng dẫn route.

### Giai đoạn D — Depth Estimation + Walkable Area (thay `danger_for()` theo diện tích)
- Trên `ai_server`: thêm model MiDaS Small hoặc Depth Anything V2 Small,
  endpoint mới `/depth` (hoặc gộp vào `/detect` trả thêm `depth_map`/
  `walkable_mask`).
- Thuật toán: Depth Map → gradient → normal vector → phân loại
  walkable/non-walkable theo mặt phẳng (mục 7 trong bản thiết kế) — độc lập
  với YOLO, để vật cản không thuộc `OBSTACLE_CLASSES` vẫn được phát hiện.
- YOLO giữ vai trò bổ sung ngữ nghĩa (mục 8): sau khi Depth Analysis báo "có
  vật cản", chạy YOLO lên vùng đó để suy ra tên vật cản, giữ nguyên
  `ObstacleReasoningService` hiện tại làm bước cuối.
- Tiêu chí xong: vật cản lạ (không có trong `OBSTACLE_CLASSES`) vẫn được cảnh
  báo nhờ walkable-area, không chỉ nhờ YOLO.

### Giai đoạn E — Re-routing
- `RouteFollower` phát sự kiện `offRoute` hoặc `SessionController` phát hiện
  cảnh báo vật cản lặp lại nhiều cycle liên tiếp trên toàn bộ chiều rộng khung
  hình → gọi lại `/route` từ vị trí hiện tại, hoặc áp dụng né cục bộ (giữ
  hướng đi theo waypoint tiếp theo nhưng lệch trái/phải theo vùng walkable
  trống).
- Tiêu chí xong: giữ thiết bị cố ý lệch khỏi waypoint → nghe
  `"Bạn đã đi lệch khỏi tuyến đường"` rồi route tự tính lại.

### Giai đoạn F — On-device (TensorFlow Lite)
- Không bắt buộc cho MVP; chỉ nên làm sau khi giai đoạn D ổn định. Mục tiêu:
  chuyển YOLO + depth model nhẹ sang chạy trực tiếp trên điện thoại bằng
  `tflite_flutter`, giảm phụ thuộc mạng/độ trễ cho phần an toàn (Environmental
  AI), giữ routing/geocoding trên server vì cần dữ liệu bản đồ lớn — đúng
  triết lý Edge–Server đã đặt ra.

## 6. Ghi chú thiết kế cần giữ nguyên khi mở rộng

- Một `CameraController`/một `FrameSource` duy nhất cho preview và pipeline AI
  — không tạo stream camera thứ hai khi thêm depth model.
- `SessionController` là nơi duy nhất hợp nhất route + perception + voice;
  UI (`HomeScreen`, `StatusPanel`, `PerceptionPreview`, `TalkButton`) chỉ
  quan sát stream, không chứa logic quyết định.
- Giữ interface `RouteService` khi thêm `OsrmRouteService` — cho phép chạy
  song song bản heuristic GPS (demo không cần mạng) và bản OSRM thật bằng
  cách đổi implementation tại nơi khởi tạo `SessionController` trong
  [lib/main.dart](../lib/main.dart), không đổi phần còn lại của app.

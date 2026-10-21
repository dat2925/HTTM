# Handoff: dẫn đường đi bộ — 14/10/2026

Lớp trợ lý OpenAI được bổ sung độc lập sau handoff này: [HANDOFF_OPENAI_ASSISTANT.md](HANDOFF_OPENAI_ASSISTANT.md). Core navigation của tài liệu này tiếp tục là nguồn chỉ dẫn chính.

## Yêu cầu và kết quả

- Đổi routing ô tô sang Valhalla `pedestrian`, giữ geometry đầy đủ.
- Hiển thị vị trí thật trên nền OpenStreetMap ngay khi có GPS, không cần đặt đích và không phụ thuộc camera.
- Mũi tên xanh chỉ **đầu điện thoại**; đường cam chỉ hướng theo lối đi. Bản đồ khóa hướng Bắc, có nút trở về vị trí.
- Đo tiến độ bằng phép chiếu GPS lên polyline; khoảng cách còn lại tính theo đường.
- Lưu vệt GPS đã đi riêng với tuyến còn lại, khôi phục hành trình sau khi mở lại app.
- Kiểm tra mỗi 5 giây; khi đã đi thêm >=5 m thì cập nhật tuyến tối đa mỗi 30 giây. Lệch tuyến qua 3 fix tốt kích hoạt cập nhật sớm, cách yêu cầu trước ít nhất 10 giây. Đứng yên không gọi routing liên tục.
- TTS có chỉ dẫn hướng và rẽ, đọc lại, đọc vị trí/địa chỉ; cảnh báo vật cản có ưu tiên cao hơn.
- Nhập địa điểm bằng bàn phím, nhấn giữ để nói, hoặc nhấn giữ trên bản đồ. Xác nhận địa điểm trước khi bắt đầu.

## Handoff 1 — Backend

Chủ điểm: `ai_server/routing.py`, `main.py`, `geocoder.py`.

- `/health`: `status=ok`, `routing_profile=pedestrian`, `api_version=2`.
- `/route`: trả `profile`, `provider`, `geometry: [[lat,lng],...]`, `waypoints` có `shape_index`, `type`, `street_name`, và tổng khoảng cách/thời gian.
- `/geocode`: thêm `near_lat`, `near_lng` để ưu tiên vùng hiện tại; `/reverse` trả địa chỉ gần GPS khi người dùng yêu cầu.
- Nominatim có cache 5 phút và khóa giãn cách tối thiểu 1.1 giây trong **một process**. Chạy một worker; nhiều worker cần rate limit/cache dùng chung.
- `VALHALLA_URL` mặc định `https://valhalla1.openstreetmap.de`. Có thể trỏ tới server tự host; không có fallback ô tô.
- Route bị lỗi trả 502; input tọa độ ngoài phạm vi bị FastAPI từ chối 422.
- Backend production đang dùng API cũ phải được cập nhật cùng client. Client sẽ từ chối route thiếu `profile=pedestrian`/geometry và thông báo cần cập nhật server.

## Handoff 2 — Navigation engine

Chủ điểm: `PedestrianRouteService`, `RouteTracker`, `WalkingRoute`, `LocationSource`, `JourneyStore`.

- `RouteService` có snapshot ban đầu, stream trạng thái, `Future<bool> setDestination`, `refresh`, hủy đích, xóa hành trình, pause/resume.
- Không còn đích demo tự đặt hoặc implementation OSRM/bearing-only.
- `RouteTracker` dùng cửa sổ tiến độ dọc tuyến, tránh nhảy sang nhánh quay về ở tuyến song song/giao cắt. Đây là map matching cục bộ, chưa phải HMM.
- GPS >25 m sai số hoặc cũ >15 giây: tạm ngừng chỉ hướng; timer lấy fix mới khi đứng yên. Loại fix đảo thứ tự và bước nhảy không hợp lý với đi bộ.
- Lệch tuyến: khoảng cách ngang tuyến >max(12 m, 1.8×accuracy), cần 3 fix liên tiếp; không dùng bán kính cố định để chuyển waypoint.
- Đến nơi: gần cuối polyline và gần đích thật với dung sai theo accuracy giới hạn 5–12 m; cần 3 fix tốt liên tiếp.
- Hướng theo điểm nhìn trước 6–18 m trên đường, có làm mượt la bàn quanh 0°/360°, lọc accuracy và hết hạn sau 10 giây.
- Mỗi thay đích/pause tăng generation; response cũ không thể ghi đè tuyến mới. Lỗi refresh giữ tuyến của **cùng đích**; đổi đích luôn xóa tuyến cũ.
- Journey lưu cục bộ bằng SharedPreferencesAsync, giãn ghi 5 giây và ghi khi đổi đích/pause/đến nơi. Giữ 10.000 điểm gần nhất cùng tổng quãng đường. Có chỉ số ngắt đoạn để không vẽ đường nối xuyên qua thời gian app dừng.

## Handoff 3 — UI / Voice

Chủ điểm: `HomeScreen`, `NavigationMap`, `SessionController`, `TtsService`.

- Trang chính ưu tiên bản đồ. Camera mở qua icon; lỗi camera không khóa dẫn đường GPS.
- Hiện sai số, hướng đầu điện thoại, hướng lối đi, đã đi/còn lại; nút GPS, đọc lại, refresh và hủy đích.
- Màn hình hành trình có bản đồ thật, các chỉ dẫn và nút xóa dữ liệu đã lưu.
- Lệnh: “đi đến ...”, “xác nhận”, “hủy”, “tôi ở đâu”, “nhắc lại”, “dừng dẫn đường”. STT vẫn dùng nhấn giữ; khi đang nghe, TTS tạm im, haptic vẫn hoạt động.
- Không đọc “an toàn” chỉ vì YOLO không phát hiện; dùng “chưa phát hiện vật cản”. Không suy ra vùng đi được hoặc né trái/phải từ YOLO.

## Cách chạy

Từ thư mục workspace:

```powershell
cd ai_server
.\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000
```

Mở terminal khác tại workspace:

```powershell
flutter pub get
flutter run --dart-define=AI_SERVER_URL=http://<IPv4-laptop>:8000
```

Điện thoại và laptop cùng mạng; kiểm tra `/health` từ trình duyệt điện thoại. Android emulator có thể dùng `http://10.0.2.2:8000`. `.venv` ở gốc đang trỏ Python đã mất; dùng **ai_server/.venv** (Python 3.11).

## Kiểm tra tự động và thực địa

Kết quả trên workspace: analyzer không có issue; 23 test Flutter và 8 test Python đạt; build APK debug thành công tại `build/app/outputs/flutter-apk/app-debug.apk`. Có widget test cho màn hình 360×640 và bàn phím/chữ lớn. Chưa có điện thoại Android kết nối để xác minh GPS/la bàn thực địa. Build có cảnh báo sẵn từ `flutter_tts` về KGP cần nâng cấp trước một phiên bản Flutter tương lai; hiện không chặn build.

```powershell
flutter analyze --no-pub
flutter test --no-pub
ai_server\.venv\Scripts\python.exe -X utf8 -B -m unittest discover -s ai_server -p "test_*.py" -v
```

Đã gọi thật Valhalla với tọa độ demo Hà Nội: route pedestrian, 784 m, 85 điểm geometry. Kết quả này xác minh kết nối và parsing, không chứng minh chất lượng dẫn đường ngoài thực địa.

Checklist trên điện thoại:

1. Mở app chưa đặt đích: vị trí hiện trên bản đồ, sai số hiển thị, xoay điện thoại kiểm tra mũi tên.
2. Nhấn “tôi ở đâu”: nghe địa chỉ gần GPS, hướng và sai số.
3. Chọn đích gần, xác nhận: có polyline đi bộ và chỉ dẫn TTS.
4. Đi qua đoạn cong và giao lộ: hướng bám đường; không tiếp tục đọc thao tác rẽ đã qua.
5. Đi thêm 30–50 m: vệt xanh lá giữ nguyên khi phần xanh dương cập nhật.
6. Lệch tuyến: sau các fix đáng tin cậy, nghe thông báo và nhận tuyến mới.
7. Mất mạng: trạng thái lỗi rõ, giữ route của cùng đích; đổi đích thất bại không giữ đường cũ.
8. Tắt GPS/từ chối quyền: thông báo rõ; bật lại và nhấn refresh để thử lại.
9. Mở lại app: vệt đã đi còn, không nối qua khoảng cách lúc app dừng; đích còn dở được tính lại từ GPS mới.
10. Đặt đích tại vị trí thực tế: đến nơi chỉ khi đủ 3 fix tốt, không do la bàn cập nhật.

## Phần cần tiếp tục

- Xác minh thực địa GPS và tư thế cầm máy: la bàn đang đo đầu điện thoại, không suy ra hướng người dùng/camera hay vị trí chính xác trên vỉa hè. Giữ đầu máy hướng về phía trước.
- Nền bản đồ và routing public cần Internet, không có SLA; khi đưa vào vận hành cần nhà cung cấp hoặc tự host phù hợp tải, cùng rate limiting chung.
- SharedPreferences phù hợp lưu hành trình gần đây, không phải nhật ký bền vững; nếu cần lưu nhiều chuyến/export dùng cơ sở dữ liệu/GPX.
- App tạm dừng GPS khi vào nền; chưa có foreground location service cho dẫn đường khi khóa màn hình.
- OSM/Valhalla không đảm bảo vỉa hè, lối sang đường, công trình tạm hay accessibility hoàn chỉnh. Camera vẫn YOLO bbox heuristic, chưa có depth/walkable-area.
- Chưa có tránh vật cản chủ động hoặc quyết định sang đường. TTS ưu tiên cảnh báo, không sửa geometry theo vật cản.
- Nếu cần bản đồ offline hoặc định vị trong nhà, đây là các hạng mục riêng.

Nguồn hợp đồng API: https://valhalla.github.io/valhalla/api/route/api-reference/

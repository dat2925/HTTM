# Báo cáo khôi phục HTTM từ fork — 21/10/2026

## Phạm vi và nguồn

- Nguồn chỉ đọc: `E:\thieuh\FolderCode\Flutter\HTTM`, nhánh `main`, HEAD `044ea60`, tracking `origin/main`, remote `https://github.com/thieuhua/HTTM.git`.
- Đích: `E:\thieuh\FolderCode\Flutter\HTTM-clean`, nhánh `feat/thieu`, HEAD ban đầu `7ab0b90`, tracking `origin/feat/thieu`, remote `https://github.com/dat2925/HTTM.git`. Nhánh `main` cục bộ cũng ở `7ab0b90`.
- Đã kiểm tra lại HEAD, nhánh, remote, lịch sử và working tree; không fetch, merge, cherry-pick, reset, rebase hoặc push. Các remote-tracking ref là thông tin đã có ở máy.
- Fork sạch ở các file được Git quản lý. Đích có sẵn 701 thay đổi trong `.venv` được Git theo dõi; toàn bộ được để nguyên ngoài các commit khôi phục. Không có thay đổi ứng dụng hoặc staged file khi bắt đầu.
- Không tìm thấy `AGENTS.md` áp dụng trong workspace/các thư mục cha đã kiểm tra.
- Sau chỉ thị bổ sung của người dùng, ưu tiên hoàn tất trợ lý AI và tạm hoãn việc mở rộng sửa bug ngoài phạm vi khôi phục.

## Khảo sát hai cây file

Đã so sánh nội dung file thực tế, không chỉ dùng Git diff/log. Inventory ban đầu: [restoration-initial-inventory.json](restoration-initial-inventory.json). Nhiều file khác hash chỉ vì CRLF/LF; toàn bộ model/service dẫn đường chung và backend trợ lý đã tương đương nội dung fork từ đầu.

Thiếu thực sự: 10 module Flutter, 5 file test, `.env.example`, `.vscode/settings.json`, script chạy backend. Ba file riêng upstream được giữ: `ai_server/test_detect_endpoint.py`, `docs/HANDOFF_PERSON_2.md`, `lib/screens/ai_navigation_screen.dart`.

Không đưa vào đối chiếu mã nguồn: virtualenv, `.git`, Dart/Flutter cache, build, Gradle/Kotlin cache, plugin registrant sinh tự động, `local.properties`, trọng số YOLO, `.env` thực, private assistant state/QR, cấu hình cá nhân `.claude`. Không sao chép secret hoặc môi trường từ fork. Ba file Gradle bootstrap chỉ có ở nguồn (`gradlew`, `gradlew.bat`, `gradle-wrapper.jar`) đang bị ignore; không phục hồi binary/bootstrap sinh từ công cụ.

Không phát hiện file chức năng bị đổi tên cần ánh xạ lại. `ai_navigation_screen.dart` là màn hình legacy riêng upstream, giữ nguyên và không đưa vào entry point.

## Bản đồ tích hợp

```text
main.dart -> HomeScreen -> SessionController
  |-> PedestrianRouteService -> LocationSource + CompassService
  |      |-> GeocodingService -> /geocode + /reverse -> Nominatim
  |      |-> RoutePlanningService -> /route -> Valhalla pedestrian
  |      |-> WalkingRoute + RouteTracker -> RouteProgress -> NavigationMap
  |      `-> JourneyStore (vệt GPS và đích lưu trên thiết bị)
  |-> FrameSource -> AiDetectionService -> /detect -> YOLO
  |      `-> DetectionResult -> ObstacleReasoningService -> UI/TTS/haptic
  |-> TalkButton -> VoiceService -> VoiceCommand.parse -> lệnh local
  `-> AssistantController -> AiAssistantService -> /assistant/chat
         |-> GPS/tuyến/YOLO + ảnh khi được yêu cầu -> backend assistant -> Responses API
         |-> AssistantPanel + AssistantScreen -> xác nhận proposal -> SessionController
         `-> pairing mã/dán/QR -> token thiết bị trong FlutterSecureStorage
```

Navigation và YOLO không phụ thuộc việc AI được ghép nối hoặc provider hoạt động. Một camera được chia sẻ giữa nhận diện, ảnh AI và QR. `PairingQrScreen.scan` chờ route scanner và native scanner dispose xong trước khi trả camera.

## Kết quả theo giai đoạn

| Giai đoạn | File/thay đổi | Hành vi và kiểm chứng |
|---|---|---|
| 0 — nền tảng | Thêm 2 controller, `assistant_state`, 3 screen, 2 service AI, 2 widget và 5 test đúng fork; thêm `.env.example` | `main.dart` giữ nguyên, đã gọi đúng HomeScreen/SessionController. Pub get thành công; analyze sạch; 44 test gốc qua trước các bổ sung |
| 1 — đi bộ | Giữ nguyên model, route service/tracker/planner, location, geocoder, journey store, map và test hiện có vì nội dung đã trùng fork | Test GPS trước chọn đích, GPS kém, đến đích, tuyến lỗi, phản hồi cũ, lệch tuyến, tính lại định kỳ, giữ vệt, khôi phục vệt, compass qua hướng Bắc đều qua; không thay bằng route ô tô |
| 2 — perception | Giữ YOLO, reasoning, endpoint và test backend upstream; tích hợp có chọn lọc timeout và cleanup camera từ `934a2a7` (`origin/fix/dat`); bổ sung test điều phối | Một request nhận diện, timeout cả header/body và abort, dừng khi health check đang chờ, bỏ detection cũ, backend lỗi vẫn đọc route, cooldown/haptic/TTS đã qua test |
| 3 — giọng nói | Khôi phục controller/TalkButton fork; giữ VoiceService và command router đang tương đương fork; thêm test TTS upstream | Lệnh local dùng được khi AI chưa paired; STT/text chung router; đích phải xác nhận; lệnh local hủy phản hồi AI đang chờ; cảnh báo ưu tiên hơn AI. Không mở rộng sửa lỗi STT sau yêu cầu tạm hoãn bug |
| 4 — AI | Khôi phục toàn bộ controller/model/service/policy/screen/panel của fork; giữ backend AI hiện có | 20 test Flutter AI/UI/session gốc và 6 test bổ sung token/context/cancel/timeout qua. Backend test xác nhận proposal, giới hạn tool, ảnh, auth, expiry, rate/budget và timeout qua |
| 5 — pairing | Khôi phục PairingQrScreen, quản lý ghép nối trong AssistantScreen và camera lease trong SessionController | Test mã sai giữ input, retry, rời màn hình khi pairing, QR không tự enroll, token hết hạn, unpair lỗi vẫn xóa token cục bộ, HTTPS/private HTTP debug, chờ capture trước QR và loại detection cũ đều qua |
| 6 — tích hợp | Giữ nguyên toàn bộ test fork; bổ sung test service AI/context, detection, device coordination và TTS | 62 Flutter test và 34 Python test qua; không có test bị skip |
| 7 — cấu hình/tài liệu | Khôi phục README/DEMO_SETUP và VS Code setting; sửa hướng dẫn AI clone mới; thêm script chạy tương đối và báo cáo | Giữ `pydantic>=2.0,<3.0`, ignore virtualenv của upstream và lockfile đã resolve được với SDK hiện tại. Không đưa `.env`/venv/cache mới vào commit |

## Khác biệt có chủ đích với fork

1. Module chuyên biệt AI (`assistant_controller`, `assistant_state`, `assistant_service`, `assistant_policy`, `assistant_screen`, `pairing_qr_screen`, `assistant_panel`) giữ nguyên nội dung fork. Backend AI cũng giữ nguyên mã nguồn; chỉ cập nhật tài liệu setup.
2. `SessionController`/`HomeScreen` giữ kiến trúc điều phối fork, bổ sung tuần tự hóa native camera, nhả/mở camera khi pause/resume, kiểm tra epoch sau health check, bỏ detection sau dispose và xử lý lỗi perception bất ngờ. Queue không giữ Future đã xong để các test widget/dispose không treo khi đổi async zone. Không thay navigation bằng callback/stub của nhánh thiết bị upstream.
3. `AiDetectionService` có deadline toàn request và abort; `FrameSource` dọn camera khi init thất bại và nhả controller cũ trước mở controller mới. Đây là các cải tiến hợp lệ đọc từ upstream `934a2a7`, không lấy phần loại bỏ navigation/assistant của nhánh đó.
4. `pubspec.lock` giữ 6 phiên bản transitive khác fork (`clock`, `code_assets`, `hooks`, `objective_c`, `record_use`, `stack_trace`). Không khác dependency trực tiếp trong `pubspec.yaml`; pub get, analyze và test đã xác nhận lockfile hiện tại. Không nâng dependency ngoài yêu cầu.
5. Requirements giữ thêm ràng buộc Pydantic 2 của upstream. `.gitignore` giữ thêm ignore cho virtualenv ở gốc.
6. `run_web_8081.bat` giữ hành vi khởi động backend cổng **8001** như fork; tên cũ không có nghĩa là chạy Flutter Web. Đổi đường dẫn tuyệt đối trỏ vào nguồn fork thành `%~dp0ai_server` để không ghi/cài phụ thuộc vào nguồn tham chiếu; gọi Python trong venv trực tiếp. Script chưa chạy server thực tế trong phiên này.
7. README/DEMO_SETUP phản ánh HomeScreen và pipeline đi bộ/AI. Giữ tài liệu upstream dưới dạng lịch sử, bổ sung liên kết báo cáo này; sửa thông tin cũ khẳng định clone đã có API key.

## Lệnh và kết quả kiểm thử

Môi trường: Flutter **3.47.4**, Dart **3.13.3**, Python **3.11** trong `ai_server/.venv` mới, tách khỏi `.venv` gốc có thay đổi sẵn.

Từ workspace đích:

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub --reporter expanded --timeout 20s
```

Kết quả cuối: pub get thành công; analyze **No issues found**; **62/62** test Flutter qua. Có thông báo của flutter_map về tile OSM khi test widget; không phải lỗi test.

```powershell
py -3.11 -m venv ai_server/.venv
ai_server/.venv/Scripts/python.exe -m pip install -r ai_server/requirements.txt
Push-Location ai_server
.venv/Scripts/python.exe -X utf8 -B -m unittest discover -p 'test_*.py' -v
Pop-Location
```

Kết quả cuối: **34/34** Python test qua. Test lỗi inference chủ động mock RuntimeError và nhận HTTP 500; log lỗi trong test đó là hành vi mong đợi. FastAPI/Starlette đang cài phát cảnh báo deprecation TestClient/httpx, không làm test thất bại.

Các lần kiểm thử trung gian đã gặp lỗi: môi trường Python chưa cài xong; test upstream chưa khởi tạo dotenv theo API 6.0.1; lỗi stop/health tái hiện được; kiểu generic nullable; lint; queue camera gây chờ trong widget test. Đã xử lý các lỗi tích hợp này và chạy lại bộ đầy đủ thành công. Không coi lần chạy lỗi hoặc bị dừng là kết quả thành công.

Phân loại: Flutter unit/widget với fake camera/GPS/STT/TTS/HTTP; Python unittest và FastAPI TestClient với provider/geocoder/YOLO inference được mock. Không có kiểm thử thiết bị hoặc kiểm thử liên thông OpenAI/Valhalla/Nominatim thật trong phiên này.

## Đối chiếu chức năng cuối

| Chức năng | So với fork | Kiểm chứng thực tế |
|---|---|---|
| Cấu trúc ứng dụng/HomeScreen | Tương đương fork và có cải tiến | Widget test qua; chưa chạy Android |
| GPS/compass/OSM/route pedestrian/vệt hành trình | Tương đương fork | Unit/widget/API mock qua; chưa thực địa |
| Camera/YOLO/cảnh báo | Tương đương fork và có cải tiến | Mock/API test qua; chưa camera/inference thật |
| Nhấn giữ/STT/lệnh local | Tương đương fork | Test router/session qua; chưa micro/STT thật |
| TTS thứ tự nguy hiểm → route → AI | Tương đương fork và có cải tiến kiểm thử | Native-channel mock qua; chưa nghe trên thiết bị |
| AI text/voice/context/ảnh/chủ động | Tương đương fork | Unit/UI/backend mock qua; chưa gọi OpenAI thật |
| AI proposal/xác nhận/hủy/phản hồi cũ | Tương đương fork và có cải tiến kiểm thử | Callback/expiry/context/cancel test qua |
| Pairing mã/dán/QR/token | Tương đương fork và có cải tiến kiểm thử | UI/service/backend mock qua; chưa quét QR hoặc secure storage thật |
| Camera lease và lifecycle | Tương đương fork và có cải tiến | Test chờ capture/pause/resume/epoch qua; chưa native Android |
| Setup, tài liệu, dependency | Tương đương fork và giữ bổ sung upstream | Pub get và pip install thành công |

Không còn thành phần mã nguồn fork bị thiếu trong phạm vi đối chiếu. Không có import/export/part Dart tương đối trỏ tới file không tồn tại. Chi tiết: [RESTORATION_COMPARISON.json](RESTORATION_COMPARISON.json).

Chạy lại đối chiếu (đọc fork, chỉ ghi JSON ở đích):

```powershell
py -3.11 -X utf8 tools/compare_fork.py --reference E:\thieuh\FolderCode\Flutter\HTTM --output docs/RESTORATION_COMPARISON.json
```

## Commit

- `e098238` — `restore: recover fork application modules and integration tests`.
- `452e501` — `fix: preserve upstream detection and camera lifecycle safeguards`.
- `5c861ee` — `test: verify restored assistant context pairing and cancellation` (gồm hoàn thiện queue chờ camera để bộ test AI/widget chạy đầy đủ).
- Commit tài liệu/cấu hình tiếp theo: `chore: reconcile fork setup and restoration audit`. Dùng `git log 7ab0b90..HEAD --oneline` để xem SHA cuối cùng.

## Giới hạn và việc còn lại

- `flutter devices` chỉ thấy Windows, Chrome và Edge; không có Android. Chưa xác minh quyền/native camera/QR/GPS/compass/STT/TTS/haptic hoặc lifecycle trên điện thoại.
- Không đọc/copy API key từ fork và không gọi provider có tính phí. Để bật AI thật, tạo `ai_server/.env` từ mẫu khi chưa có, điền key tại backend, tạo pairing secret/QR bằng công cụ sẵn có, chạy backend HTTPS rồi ghép nối thiết bị. `.env` Flutter chỉ có URL backend mẫu và được Git ignore.
- Bộ kiểm thử hiện tại không chứng minh toàn bộ lỗi đã được loại bỏ. Theo yêu cầu ưu tiên AI, chưa mở rộng sửa/kiểm thử các tình huống STT/lifecycle tổng quát ngoài các regression đã mô tả. Chưa hỗ trợ dẫn đường khi khóa màn hình như fork đã ghi nhận.
- `.venv` gốc vẫn có 701 thay đổi có sẵn; không dọn hoặc stage chúng. Không push GitHub.

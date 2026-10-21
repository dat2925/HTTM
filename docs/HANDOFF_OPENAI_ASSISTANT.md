# Handoff — OpenAI Assistant, 14/10/2026

Tích hợp bổ sung trên kiến trúc đi bộ hiện có. Navigation engine, GPS, routing và YOLO không gọi hoặc phụ thuộc vào phản hồi OpenAI.

## 1. Đã triển khai

- Backend gọi **Responses API** trực tiếp qua `httpx`, model mặc định `gpt-4.1-mini`; hội thoại tiếng Việt, input ảnh camera và ngữ cảnh GPS/tuyến/YOLO.
- Đọc `OPENAI_API_KEY` **chỉ** từ `ai_server/.env` với đường dẫn theo module, không dựa vào cwd hoặc Flutter dotenv. Không log key, prompt, ảnh hoặc bearer token.
- `.env` Flutter giữ nguyên, chỉ cấu hình URL backend hiện có. Token thiết bị được nhập/cấp lúc chạy, lưu bằng FlutterSecureStorage; Android tắt auto backup. Không nhúng token/key vào dart-define hoặc assets.
- `AssistantController` là lớp phụ của `SessionController`. Navigation vẫn chạy khi trợ lý chưa ghép nối, hết ngân sách, lỗi mạng, timeout hoặc OpenAI tắt.
- **Nút ghi âm chính** dùng chung `SessionController.handleUtterance` với ô nhập hội thoại. `AssistantPanel` ngay trên màn hình bản đồ hiển thị câu đã nói, nguồn xử lý, tiến độ, câu trả lời đầy đủ, lỗi và nút xác nhận/bỏ đề xuất. Không cần chuyển màn hình để đọc hoặc xác nhận AI.
- `VoiceCommand.parse` xử lý mẫu lệnh gốc trước: đi đến/dẫn tôi đến/đưa tôi tới/tới/đến + địa điểm; tôi (đang) ở đâu; nhắc lại; dừng/hủy dẫn đường; cập nhật tuyến/tính lại đường; xác nhận/đồng ý/đúng; hủy/không/không đúng. Chuẩn hóa chữ hoa, khoảng trắng, dấu câu cuối. Các lệnh này không gọi OpenAI và hoạt động khi chưa ghép nối.
- Câu ngoài mẫu chuyển tới AI. “phân tích ảnh”, “nhìn thấy gì”, “phía trước có gì”, “mô tả ảnh” yêu cầu ảnh. Không nhận diện hành động chỉ vì câu hỏi chứa cụm lệnh ở giữa. Prefix đích cần ranh giới từ; hệ thống vẫn phải xác nhận địa chỉ trước khi đổi đích.
- “xác nhận” chỉ thực hiện một yêu cầu đang chờ. Yêu cầu AI mới bỏ đích gốc chưa xác nhận, lệnh gốc mới hủy phản hồi AI đang chờ; tránh hai xác nhận xung đột. “hủy” vô hiệu hóa phản hồi đang chạy và bỏ yêu cầu chờ. UI và voice đều kiểm tra context/expiry trước khi thực hiện proposal.
- Màn hình **Trợ lý AI** tiếp tục phục vụ lịch sử, kèm ảnh, bật/tắt chủ động và quản lý ghép nối. Mã nhập sai/lỗi mạng giữ nguyên để sửa/thử lại; có dán mã, hiện/ẩn mã và quét QR. Chỉ xóa ô khi ghép nối thành công.

## 2. Handoff backend

Các module: `assistant_config.py`, `assistant_models.py`, `assistant_guard.py`, `assistant_service.py`, `assistant_router.py`.

| Endpoint | Quyền / hành vi |
|---|---|
| `POST /assistant/pair` | Mã ghép nối + UUID thiết bị; cấp bearer 24 giờ, ký HMAC, có nonce được lưu và thu hồi được |
| `GET /assistant/status` | Bearer; model và hạn mức ngày UTC |
| `POST /assistant/chat` | Bearer; context typed, request/conversation UUID, text, ảnh base64 tùy chọn |
| `POST /assistant/reset` | Bearer; xóa hội thoại RAM của client |
| `POST /assistant/unpair` | Bearer; thu hồi nonce, xóa hội thoại |

- HTTPS bắt buộc. HTTP chỉ khi backend bật `ASSISTANT_ALLOW_INSECURE_LAN=1` và remote là địa chỉ private/loopback. Uvicorn/reverse proxy phải chỉ tin proxy headers từ proxy đã biết; không cấu hình trust `*` trên server public.
- Xác thực **trước khi đọc body ảnh**; kiểm tra kích thước thật cả body chunked: pairing 4 KB, chat 1.3 MB.
- Request validation trả lỗi ngắn, không echo input/ảnh. Error OpenAI được chuyển thành mã lỗi an toàn, không trả nội dung lỗi upstream.
- Token không phải OpenAI key. Pairing code giữ trên server và chỉ cung cấp cho người dùng thiết bị được cho phép. Ghép nối lại cùng device ID thay nonce cũ; rotate signing secret thu hồi mọi token.
- SQLite trong `ai_server/.assistant-state/limits.sqlite3` lưu nonce, rate events và cost reservations; Git bỏ qua. Hạn mức dùng giao dịch `BEGIN IMMEDIATE`, không reset khi server khởi động lại.
- Pairing: tối đa 5 lần/phút/remote và 20 lần/phút tổng. Chat: mặc định 6/phút/device và 24/phút tổng. Một yêu cầu đang xử lý trên mỗi device; request UUID cũ trả 409, không tự gọi lại OpenAI.
- Tối đa 4 lượt chạy model đồng thời trong một process, timeout toàn bộ 25 giây, không retry. Mỗi turn tối đa 3 API calls, 4 tool invocations, 500 output tokens/call, input payload text/tools <=24 KB/call.
- Ảnh <=900 KB sau decode, <=12 MP; resize <=768 px, re-encode JPEG xóa EXIF. Chỉ ảnh hiện tại <=10 giây được nhận.

## 3. Function calling và quyền thực thi

Các tools strict schema:

1. `get_journey_status`: đọc **device-reported** context, không chứng nhận sự thật/an toàn.
2. `search_places`: gọi geocoder hiện có, ưu tiên vị trí báo cáo; tối đa một kết quả/turn.
3. `propose_navigation_action`: tạo **proposal**, không thực thi. `set_destination` chỉ dùng place ID do geocoder tạo trong chính turn đó; không nhận tọa độ tự tạo từ model.

Action allowlist: `set_destination`, `refresh_route`, `cancel_navigation`, `repeat_instruction`, `describe_location`. Mọi proposal đều `requires_confirmation=true`; client kiểm tra allowlist, tọa độ, hạn sử dụng và ngữ cảnh rồi chờ người dùng. Model không có tool đi thẳng/sang đường/xác nhận an toàn.

Nếu có proposal, câu trả lời được thay bằng thông báo chờ xác nhận do backend tạo, để model không tự nhận đã thực hiện. Với câu hỏi về chỉ dẫn, `kind=route_status` lấy nguyên chỉ dẫn navigation engine do thiết bị báo, thay vì đọc hướng do AI tự tạo.

## 4. TTS, camera, stale responses và chủ động

- Camera dùng chung `FrameSource`. Loop YOLO giữ một JPEG gần nhất trong RAM. Yêu cầu ảnh AI dùng frame <=5 giây hoặc chụp bổ sung khi camera không đang bận; không mở stream khác. Chụp bổ sung chỉ giữ khóa camera ngắn, không giữ trong lúc chờ OpenAI.
- AI TTS priority **0**, route **1**, thao tác/voice **2**, cảnh báo vật cản **3**. Không đọc AI khi STT đang nghe, có vật cản, vừa có cảnh báo hoặc route vừa được đọc trong 8 giây. Có thể hiển thị câu trả lời nhưng bỏ phần TTS nếu nó hết hạn.
- Phản hồi có TTL 15 giây, proposal 45 giây. Client chặn khi request đã bị thay/cancel, pause, đổi đích/tuyến/trạng thái, đi thêm >10 m hoặc context request quá 30 giây. Nhận phản hồi và bấm xác nhận đều kiểm tra lại.
- Backend chặn context request >30 giây hoặc ảnh >10 giây. Client đóng HTTP client khi cancel/timeout; backend có timeout độc lập. Hủy client không đảm bảo provider chưa tính phí, nên reservation vẫn bảo thủ.
- Chủ động mặc định **tắt**, user bật trong màn hình trợ lý. Trigger: off-route/error/poor-GPS tồn tại ít nhất 10 giây; không gọi khi có cảnh báo hoặc đang nghe. Ít nhất 120 giây giữa các trigger và sau tương tác user; sự kiện giống nhau dedupe 10 phút. Không polling model mỗi frame/GPS.
- Proactive chỉ có read tool `get_journey_status`, không search hoặc proposal, không gửi ảnh, trả tối đa 220 ký tự. Chỉ thông tin mới; notification có thể im khi ngữ cảnh thay đổi hoặc ưu tiên cao đang hoạt động.

## 5. Ngân sách

Mặc định: toàn backend **1 USD/ngày UTC**, mỗi device **0.5 USD/ngày**. Reservation tối đa **0.05 USD/turn** trước khi gọi; đã biết usage thì quyết toán theo token. Timeout/lỗi không có usage giữ reservation, không hoàn giả định.

Giới hạn text UTF-8 bytes, ảnh 768 px, số round và output được chọn để reservation phủ giới hạn token của model allowlist. Bảng tính dùng input 0.40 / output 1.60 USD mỗi triệu token, tính input cached như input thường cho bảo thủ. Model allowlist chỉ `gpt-4.1-mini` và snapshot tương ứng. Không cho client chọn model; model khác fail closed. Khi thay model/giá phải cập nhật estimator và tests trước.

Biến backend `.env`: `OPENAI_ASSISTANT_MODEL`, `ASSISTANT_DAILY_USD`, `ASSISTANT_DEVICE_DAILY_USD`, `ASSISTANT_RPM`. Đây là hạn mức của ứng dụng này, không phải toàn bộ tài khoản OpenAI hoặc các ứng dụng khác dùng cùng key.

## 6. Cấu hình và chạy

Clone mới chưa có `ai_server/.env`. Tạo file từ mẫu, tự điền `OPENAI_API_KEY` tại backend nếu muốn bật trợ lý. Không sao chép `.env` từ thư mục fork. Công cụ setup chỉ bổ sung secret ghép nối/ký nếu thiếu, không in hoặc đổi OpenAI key.

Từ workspace:

```powershell
py -3.11 -m venv ai_server/.venv
ai_server\.venv\Scripts\python.exe -m pip install -r ai_server/requirements.txt
if (-not (Test-Path ai_server/.env)) { Copy-Item ai_server/.env.example ai_server/.env }
# Điền OPENAI_API_KEY trong ai_server/.env trước khi sử dụng trợ lý thật.
ai_server\.venv\Scripts\python.exe ai_server/setup_assistant.py --show-pairing-code
ai_server\.venv\Scripts\python.exe ai_server/setup_assistant.py --qr
```

Kết quả khôi phục và kiểm thử hiện tại: [RESTORATION_REPORT.md](RESTORATION_REPORT.md). Các kết quả thực địa ghi trong tài liệu bàn giao cũ không thay thế việc kiểm tra trên thiết bị hiện tại.

Lệnh thứ hai chỉ in trạng thái key và **mã ghép nối**, không in API key. Cung cấp mã qua kênh riêng cho thiết bị được phép. Không đặt mã vào Flutter `.env` hoặc source.

`--qr` tạo `ai_server/.assistant-state/pairing-qr.png` cục bộ, đã được Git ignore, không có endpoint HTTP phục vụ ảnh này. QR chứa JSON `{type: smart_navigation_pairing, version: 1, pairing_code: ...}`; chỉ mã thiết bị, không API key hoặc signing secret. Giữ QR riêng như mã ghép nối. Công cụ không đổi các secret đã có. Thư viện Python `qrcode[pil]` được thêm vào requirements.

Trên app chọn **Kết nối trợ lý → Quét QR**, quét ảnh từ màn hình máy tính, rồi bấm **Ghép nối**. Quét không tự cấp token. QR chỉ điền mã, không sửa `AI_SERVER_URL` hoặc chuyển backend; payload có URL/trường lạ/bản không hỗ trợ bị từ chối. Có thể dán mã hoặc JSON QR từ clipboard. Mã QR hỗ trợ 12–128 ký tự URL-safe; mã backend cũ có ký tự khác vẫn có thể nhập tay.

Scanner dùng `mobile_scanner` với ML Kit bundled trên Android. `SessionController.suspendCameraForQr` tạm dừng camera/YOLO, chờ capture tối đa 10 giây, giải phóng camera duy nhất; GPS và route TTS tiếp tục. Bộ quét dispose xong mới khôi phục camera/YOLO. Kết quả YOLO từ trước scan bị bỏ theo epoch. Thông báo trên màn quét yêu cầu đứng yên vì cảnh báo camera đang tạm dừng. Hủy/quét sai/lỗi quyền giữ ô mã cũ và đi qua cùng luồng khôi phục.

Chạy backend theo `DEMO_SETUP.md`, cập nhật backend và APK cùng nhau. URL Flutter giữ như hiện tại; backend được chọn phải có `/assistant/*` mới. Production cần HTTPS và reverse proxy đúng cấu hình.

Nếu thử bằng HTTP mạng nội bộ: thêm **chỉ vào `ai_server/.env`** `ASSISTANT_ALLOW_INSECURE_LAN=1`, restart backend và bật checkbox HTTP nội bộ trong màn hình ghép nối của **APK debug**. Release vẫn từ chối HTTP; không áp dụng cho endpoint public.

Trên app: dùng nút nói chính cho lệnh hoặc câu hỏi AI. Mở icon hội thoại/Kết nối trợ lý để ghép nối và quản lý lịch sử. Token hết hạn sau 24 giờ thì ghép nối lại. Chọn kèm ảnh cho câu hỏi thị giác hoặc nói các mẫu yêu cầu ảnh. Có thể bật thông tin chủ động sau khi ghép nối; default tắt.

## 7. Xác minh

Sau cập nhật giao diện/QR: **44 test Flutter và 30 test Python đạt**, analyzer không có issue. Kiểm thử bao gồm pointer down/up của nút nói chính → AI → hiển thị/xác nhận trên bản đồ; lệnh gốc không gọi AI kể cả chưa ghép nối; typed input dùng cùng router; hủy reply AI cũ; mã sai giữ nguyên và thử lại; QR hợp lệ/không hợp lệ/hủy giữ input và không tự pair; chờ camera capture nhưng không chờ YOLO network; GPS/route TTS tiếp tục; YOLO cũ không quay lại sau restore. Kiểm thử rời màn hình khi pair đang chạy không truy cập controller đã dispose. PNG thử nghiệm được giải mã đối chiếu đúng payload bằng OpenCV.

APK debug đã build thành công với scanner mới. Secret boundary quét **598 entries**, không tìm thấy OpenAI key, pairing code hoặc signing secret; QR/state riêng cũng không nằm trong APK hoặc Git. Bản cập nhật giao diện/QR không chỉnh Flutter `.env`; lần kiểm tra cuối đối chiếu hash cấu hình hiện tại thành công. Backend `.env` và ảnh QR được Git ignore. Cảnh báo build KGP từ `flutter_tts` hiện có không chặn build.

```powershell
flutter analyze --no-pub
flutter test --no-pub
ai_server\.venv\Scripts\python.exe -X utf8 -B -m unittest discover -s ai_server -p "test_*.py" -v
flutter build apk --debug --no-pub
```

Kiểm tra ranh giới secret sau build (không in giá trị secret):

```powershell
ai_server\.venv\Scripts\python.exe -X utf8 -B ai_server/check_secret_boundary.py --apk build/app/outputs/flutter-apk/app-debug.apk
```

Live check tự chọn, tốn phí trong hạn mức:

```powershell
ai_server\.venv\Scripts\python.exe -X utf8 -B ai_server/smoke_assistant.py --live
```

Đã kiểm tra thật với ảnh màu tổng hợp 64×64 và context giả: gpt-4.1-mini, 2 API calls, 1 function call, chi phí ước tính **0.000772 USD**. Không gửi GPS/hình ảnh cá nhân trong live test này.

Tests bao phủ auth/expiry/revoke, HTTPS/body size, restart budgets, duplicate/inflight requests, cooldown, tool loop, destination chỉ từ search, proactive không mutation, ảnh/EXIF, history isolation, timeout, safety wording, token transport, context stale, user confirmation, speech priority và layout keyboard/chữ lớn.

Trên điện thoại cần thử: quét QR thật/permission/back/background và camera trở lại YOLO; ghép nối/revoke/expiry; hỏi bằng STT trên màn hình chính; đổi đích giữa một câu hỏi; cảnh báo ngắt AI; đề xuất không tự đổi đích; mất mạng và hết budget; chủ động không lặp. Workspace hiện chưa có điện thoại Android kết nối; widget/unit tests và APK build không thay thế kiểm thử camera/STT/TTS thật.

## 8. Giới hạn còn lại

- Prompt + structured schema + allowlist + wording filter giảm lỗi; **wording filter không phải bằng chứng hoàn chỉnh về ngữ nghĩa**. AI vẫn có thể mô tả sai/hallucinate. Không có output AI nào được dùng làm tín hiệu an toàn hoặc lệnh di chuyển của engine.
- Chưa có định vị/độ sâu tốt hơn; giới hạn GPS/YOLO/pedestrian map của handoff trước vẫn áp dụng.
- Hội thoại text ngắn trong RAM, TTL 30 phút, tối đa 100 conversations/process, 4 cặp tin mỗi conversation; ảnh không lưu vào history/disk. Server restart mất hội thoại. Client không lưu lịch sử chat vào disk.
- `store=false` tắt lưu response ở API, không đồng nghĩa OpenAI Zero Data Retention. Phải kiểm tra chính sách dữ liệu/project của nhà vận hành.
- Token shared pairing phù hợp demo/private deployment; public production nên dùng user identity, quản trị device/session, enrollment mạnh hơn và gateway abuse controls. Token runtime lưu trong secure storage không chứng minh thiết bị không bị root hoặc instrument.
- SQLite dùng chung rate/budget trên một host. Hội thoại/capacity ở RAM; chạy một worker như kiến trúc Nominatim hiện có. Multi-host cần ledger/rate limiter tập trung và session store.
- Chưa có background service/Realtime streaming. AI cần mạng; khi không có mạng dùng core navigation.
- Giá/model availability có thể đổi; cần duy trì price estimator/allowlist và spend limit trên OpenAI project ngoài lớp hạn mức local.
- Router gốc là mẫu câu xác định, không phải hiểu ý định tổng quát. Câu linh hoạt hơn đi qua AI và cơ chế proposal/xác nhận. Short prefix “đến/tới” có thể tìm nhầm một câu bắt đầu như vậy; luôn hiển thị địa chỉ và đợi xác nhận, không tự dẫn đường.

## Nguồn API đã đối chiếu

- [Function calling](https://developers.openai.com/api/docs/guides/function-calling)
- [Images and vision](https://developers.openai.com/api/docs/guides/images-vision)
- [Structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs)
- [GPT-4.1 mini — modality và giá](https://developers.openai.com/api/docs/models/gpt-4.1-mini)
- [mobile_scanner — camera lifecycle và Android bundled scanner](https://pub.dev/packages/mobile_scanner)
- [Python qrcode — tạo PNG QR](https://pypi.org/project/qrcode/)

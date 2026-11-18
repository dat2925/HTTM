# Nhật ký gate Detection V2

Các phase được thực hiện tuần tự trong working tree; chưa commit/push/merge.
Báo cáo chi tiết và giới hạn: [DETECTION_V2_REPORT.md](DETECTION_V2_REPORT.md).

| Gate | Analyze | Flutter | Python | Quyết định |
|---|---|---|---|---|
| Baseline | PASS | 212 PASS | Python3.9: FAIL, 19 tests, 1 failure/6 errors/1 skip | Chuẩn bị .venv và cô lập fixture phụ thuộc weights |
| Phase 1 | PASS | 213 PASS | 72 OK, 1 skip | Tiếp tục phần không cần weights/dataset |
| Phase 2 | PASS | 216 PASS | 73 OK, 1 skip | Stream opt-in; chưa nâng mặc định |
| Phase 3 | PASS | 217 PASS | 74 OK, 1 skip | Không đổi model hoặc class thresholds thiếu validation |
| Phase 4 | PASS | 220 PASS | Không đổi từ phase 3 | Two-frame thường, high không chờ |
| Phase 5 | PASS | 223 PASS | Không đổi từ phase 3 | Risk riêng, TTL/cooldown và empty hold theo thời gian |
| Phase 6 | PASS | 226 PASS | 76 OK, 1 skip | APK debug PASS 32.6 s; thiếu kiểm chứng thiết bị/model thật |

APK debug kiểm lần đầu thành công sau phase 2 (229.2 s), bản cuối PASS (32.6 s).
Fixture kiểm thuật toán không phải kết quả benchmark. Gate phần mềm không thay thế
kiểm chứng stream/recall/cảnh báo/latency trên thiết bị thật.

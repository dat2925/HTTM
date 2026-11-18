# Task runner cho Smart Navigation. Cài: `winget install Casey.Just`, rồi chạy `just` để xem danh sách lệnh.

set windows-shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]
set shell := ["bash", "-cu"]

# Đường dẫn python trong .venv ở thư mục gốc (Windows và Linux/macOS)
py := if os_family() == "windows" { justfile_directory() / ".venv/Scripts/python.exe" } else { justfile_directory() / ".venv/bin/python" }
port := "8000"

# Liệt kê các lệnh
default:
    @just --list

# ---------- Cài đặt ----------

# Cài tất cả: venv backend + package Flutter + tạo .env nếu chưa có
setup: venv pub-get env

# Tạo .venv (Python 3.11) và cài requirements của backend
[windows]
venv:
    if (-not (Test-Path '{{py}}')) { py -3.11 -m venv .venv }
    & '{{py}}' -m pip install -r ai_server/requirements.txt

[unix]
venv:
    [ -x '{{py}}' ] || python3.11 -m venv .venv
    '{{py}}' -m pip install -r ai_server/requirements.txt

# Tạo .env từ .env.example (không ghi đè)
[windows]
env:
    if (-not (Test-Path .env)) { Copy-Item .env.example .env; 'Đã tạo .env, nhớ sửa AI_SERVER_URL' } else { '.env đã có, giữ nguyên' }

[unix]
env:
    [ -f .env ] && echo ".env đã có, giữ nguyên" || { cp .env.example .env; echo "Đã tạo .env, nhớ sửa AI_SERVER_URL"; }

# flutter pub get
pub-get:
    flutter pub get

# ---------- Backend ----------

# Chạy backend (mặc định cổng 8000). Ví dụ: just server 8001
[working-directory: 'ai_server']
server p=port:
    {{ if os_family() == "windows" { "&" } else { "" } }} '{{py}}' -m uvicorn main:app --host 0.0.0.0 --port {{p}}

# Chạy backend có tự reload khi sửa code
[working-directory: 'ai_server']
server-dev p=port:
    {{ if os_family() == "windows" { "&" } else { "" } }} '{{py}}' -m uvicorn main:app --host 0.0.0.0 --port {{p}} --reload

# Gọi /health của backend đang chạy
health p=port:
    {{ if os_family() == "windows" { "curl.exe" } else { "curl" } }} -s http://localhost:{{p}}/health

# Tạo khóa ký + mã ghép nối cho trợ lý AI
[working-directory: 'ai_server']
assistant-setup:
    {{ if os_family() == "windows" { "&" } else { "" } }} '{{py}}' setup_assistant.py

# Tạo ảnh QR ghép nối (.assistant-state/pairing-qr.png)
[working-directory: 'ai_server']
assistant-qr:
    {{ if os_family() == "windows" { "&" } else { "" } }} '{{py}}' setup_assistant.py --qr

# ---------- App Flutter ----------

# flutter run (thêm tham số, ví dụ: just run -d emulator-5554)
run *args:
    flutter run {{args}}

# Build APK release
build:
    flutter build apk --release

# Cài APK release lên máy qua adb
install:
    adb install -r build/app/outputs/flutter-apk/app-release.apk

# Build rồi cài lên điện thoại
deploy: build install

# Liệt kê thiết bị
devices:
    flutter devices

# ---------- Kiểm tra ----------

# Chạy toàn bộ: analyze + test Flutter + test backend
check: analyze test test-server

# flutter analyze
analyze:
    flutter analyze

# flutter test
test *args:
    flutter test {{args}}

# Test backend (unittest)
[working-directory: 'ai_server']
test-server:
    {{ if os_family() == "windows" { "&" } else { "" } }} '{{py}}' -X utf8 -B -m unittest discover -p "test_*.py"

# dart format cho lib/ và test/
fmt:
    dart format lib test

# ---------- Dọn dẹp ----------

# flutter clean
clean:
    flutter clean

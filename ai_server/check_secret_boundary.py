"""Verify backend secrets are absent from Flutter source/assets/Git/APK.

Prints only pass/fail metadata, never secret values or file contents.
"""
import argparse
import hashlib
import subprocess
import zipfile
from pathlib import Path
from dotenv import dotenv_values


def check(apk: Path | None, expected_hash: str | None):
    root = Path(__file__).resolve().parent.parent
    values = dotenv_values(root / 'ai_server' / '.env', interpolate=False)
    secrets = [value.encode() for key, value in values.items()
               if key in {'OPENAI_API_KEY', 'ASSISTANT_PAIRING_CODE', 'ASSISTANT_SIGNING_SECRET'} and value]
    if not secrets: raise RuntimeError('Backend secrets not configured')
    flutter_env = (root / '.env').read_bytes()
    flutter_values = dotenv_values(root / '.env', interpolate=False)
    if {'OPENAI_API_KEY', 'ASSISTANT_PAIRING_CODE', 'ASSISTANT_SIGNING_SECRET'} & flutter_values.keys():
        raise RuntimeError('Backend secret configuration in Flutter env asset')
    if expected_hash and hashlib.sha256(flutter_env).hexdigest().upper() != expected_hash.upper():
        raise RuntimeError('Flutter .env changed')
    if any(secret in flutter_env for secret in secrets): raise RuntimeError('Secret in Flutter env asset')
    tracked = subprocess.run(['git', 'ls-files', '-z'], cwd=root, check=True, capture_output=True).stdout.split(b'\0')
    if b'ai_server/.env' in tracked or b'.env' in tracked: raise RuntimeError('Secret env file tracked by Git')
    if any(name.startswith(b'ai_server/.assistant-state/') for name in tracked):
        raise RuntimeError('Private assistant state or QR tracked by Git')
    for directory in ('lib', 'test'):
        for path in (root / directory).rglob('*.dart'):
            if any(secret in path.read_bytes() for secret in secrets): raise RuntimeError('Backend secret in Dart source')
    entries = 0
    if apk:
        with zipfile.ZipFile(apk) as package:
            for name in package.namelist():
                if 'ai_server/.env' in name: raise RuntimeError('Backend env included in APK')
                if 'pairing-qr' in name.lower() or '.assistant-state/' in name.lower():
                    raise RuntimeError('Private pairing QR/state included in APK')
                with package.open(name) as entry:
                    tail = b''
                    while True:
                        chunk = entry.read(131072)
                        if not chunk: break
                        data = tail + chunk
                        if any(secret in data for secret in secrets): raise RuntimeError('Backend secret in APK')
                        tail = data[-max(map(len, secrets)):]
                entries += 1
    print({'secret_boundary': 'passed', 'flutter_env_unchanged': bool(expected_hash), 'apk_entries_checked': entries})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--expected-flutter-env-sha256')
    args = parser.parse_args()
    check(args.apk, args.expected_flutter_env_sha256)

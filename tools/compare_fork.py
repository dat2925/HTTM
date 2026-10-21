"""Compare actual project files without reading secrets or traversing caches.

Run from the target workspace. The reference directory is read only.
"""
import argparse
import json
import os
import re
from pathlib import Path

SKIP_DIRS = {
    '.git', '.venv', '.venv-ai', '.venv-server', 'venv', '__pycache__',
    '.dart_tool', 'build', '.gradle', '.gradle-cache', '.kotlin', '.idea',
    '.pub-cache', '.pub', '.tmp', '.claude', '.assistant-state', 'node_modules',
}
SKIP_FILES = {
    'local.properties', '.flutter-plugins-dependencies', 'GeneratedPluginRegistrant.java',
    'gradlew', 'gradlew.bat', 'gradle-wrapper.jar',
}


def scan(root):
    files = {}
    for parent, directories, names in os.walk(root):
        directories[:] = [name for name in directories if name not in SKIP_DIRS]
        for name in names:
            path = Path(parent) / name
            if path.is_symlink() or name in SKIP_FILES or path.suffix in {'.pt', '.pyc', '.log'}:
                continue
            if name.startswith('.env') and name != '.env.example':
                continue
            data = path.read_bytes()
            try:
                data = data.decode('utf-8-sig').replace('\r\n', '\n').encode('utf-8')
            except UnicodeDecodeError:
                pass
            files[path.relative_to(root).as_posix()] = data
    return files


def compare(reference, target):
    source, destination = scan(reference), scan(target)
    common = source.keys() & destination.keys()
    missing_imports = []
    for path in (target / 'lib').rglob('*.dart'):
        for uri in re.findall(r"(?:import|export|part)\s+['\"]([^'\"]+)", path.read_text(encoding='utf-8-sig')):
            if ':' not in uri and not (path.parent / uri).is_file():
                missing_imports.append({'file': path.relative_to(target).as_posix(), 'import': uri})
    return {
        'normalization': 'UTF-8 BOM and CRLF only; caches, secrets and ignored Gradle bootstrap files excluded',
        'fork_only': sorted(source.keys() - destination.keys()),
        'target_only': sorted(destination.keys() - source.keys()),
        'different': sorted(path for path in common if source[path] != destination[path]),
        'identical': sorted(path for path in common if source[path] == destination[path]),
        'missing_relative_dart_imports': missing_imports,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    arguments = parser.parse_args()
    reference = arguments.reference.resolve()
    target = Path.cwd().resolve()
    if reference == target or not (reference / 'lib').is_dir():
        parser.error('Reference must be a different Flutter project directory')
    if arguments.output and not arguments.output.resolve().is_relative_to(target):
        parser.error('Output must stay inside the target workspace')
    report = compare(reference, target)
    if arguments.output:
        arguments.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(json.dumps({key: len(value) if key == 'identical' else value for key, value in report.items()}, indent=2, ensure_ascii=False))

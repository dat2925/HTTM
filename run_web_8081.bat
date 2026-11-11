@echo off
rem Legacy fork script name: starts the backend on port 8001, not Flutter Web.
rem Uses the repository-root .venv, like README.md.
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" py -3.11 -m venv .venv
if errorlevel 1 exit /b %errorlevel%
".venv\Scripts\python.exe" -m pip install -r ai_server\requirements.txt
if errorlevel 1 exit /b %errorlevel%
cd ai_server
"..\.venv\Scripts\python.exe" -m uvicorn main:app --host 0.0.0.0 --port 8001
pause

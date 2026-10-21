@echo off
rem Legacy fork script name: starts the backend on port 8001, not Flutter Web.
cd /d "%~dp0ai_server"
if not exist ".venv\Scripts\python.exe" py -3.11 -m venv .venv
if errorlevel 1 exit /b %errorlevel%
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 exit /b %errorlevel%
".venv\Scripts\python.exe" -m uvicorn main:app --host 0.0.0.0 --port 8001
pause

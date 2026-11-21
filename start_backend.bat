@echo off
title AI Vision Glasses Backend Server
cd /d C:\Users\syeda\AI_Vision_Glasses

echo =====================================================================
echo   AI Vision Glasses - Starting FastAPI Backend Server
echo =====================================================================
echo.

if not exist ".venv\Scripts\python.exe" (
    echo [ERROR] Virtual environment python not found at .venv\Scripts\python.exe! > backend_startup.log
    echo [ERROR] Virtual environment python not found at .venv\Scripts\python.exe!
    pause
    exit /b 1
)

echo Starting python main.py at %date% %time%...
echo Starting python main.py at %date% %time%... > backend_startup.log

powershell -ExecutionPolicy Bypass -Command "& { .venv\Scripts\python.exe audio_input_pipeline\main.py 2>&1 | Tee-Object -FilePath backend_startup.log }"

echo.
echo Server stopped.
pause

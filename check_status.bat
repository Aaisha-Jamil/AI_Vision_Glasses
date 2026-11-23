@echo off
set REPORT=status_report.txt
cd /d C:\Users\syeda\AI_Vision_Glasses

echo =================================================== > %REPORT%
echo   AI Vision Glasses - System Diagnostic Report     >> %REPORT%
echo   Time: %date% %time%                              >> %REPORT%
echo =================================================== >> %REPORT%
echo. >> %REPORT%

echo [1] Checking Local IPv4 Address... >> %REPORT%
ipconfig | findstr /i "IPv4" >> %REPORT%
echo. >> %REPORT%

echo [2] Checking if Port 8000 is Listening... >> %REPORT%
netstat -ano | findstr :8000 >> %REPORT%
if errorlevel 1 (
    echo Result: NOTHING is listening on port 8000! >> %REPORT%
) else (
    echo Result: Port 8000 has an active listener! >> %REPORT%
)
echo. >> %REPORT%

echo [3] Checking Python Virtual Environment... >> %REPORT%
if exist ".venv\Scripts\python.exe" (
    echo Python found: .venv\Scripts\python.exe >> %REPORT%
    .venv\Scripts\python.exe -V >> %REPORT% 2>&1
) else (
    echo Python NOT FOUND in .venv! >> %REPORT%
)
echo. >> %REPORT%

echo [4] Checking if Server Responds to HTTP on Port 8000... >> %REPORT%
curl -s -m 3 -o NUL -w "HTTP Status: %%{http_code}\n" http://localhost:8000/api/v1/glasses/capture >> %REPORT% 2>&1
echo. >> %REPORT%

echo =================================================== >> %REPORT%
echo Diagnostic complete. >> %REPORT%
type %REPORT%
pause


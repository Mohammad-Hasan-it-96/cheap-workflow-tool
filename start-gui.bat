@echo off
REM Launches the GUI with pythonw so no console window tags along.
REM Falls back to python if pythonw is missing.
setlocal
where pythonw >nul 2>nul
if %errorlevel%==0 (
  start "" pythonw "%~dp0gui\app.py"
) else (
  start "" python "%~dp0gui\app.py"
)

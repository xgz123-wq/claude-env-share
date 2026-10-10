@echo off
REM Windows 下一键打包：双击运行即可生成 dist\ClaudeEnvGuard.exe
cd /d %~dp0\..
python -m pip install -r requirements.txt pyinstaller
python packaging\build.py
pause

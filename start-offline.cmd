@echo off
REM ---------------------------------------------------------------------------
REM  Starts the whole offline stack for Pokemon Auto Chess in three windows:
REM    1. MongoDB                (localhost:27017)
REM    2. Firebase Auth emulator (localhost:9099, UI at localhost:4000)
REM    3. The game itself        (http://localhost:9000)
REM
REM  No internet connection is required once this is running.
REM  Close the three windows to stop everything.
REM
REM  WHY THIS FILE IS PURE ASCII AND LIVES IN THE REPO ROOT:
REM  cmd.exe parses batch files using the console codepage, not UTF-8. A file
REM  containing the non-ASCII repository path as a literal fails with
REM  "The filename, directory name, or volume label syntax is incorrect".
REM  %~dp0 expands to this script's own folder at RUNTIME, so the non-ASCII path
REM  never has to appear in the file. Keep this script ASCII-only, and keep it
REM  in the repository root (next to package.json).
REM ---------------------------------------------------------------------------
setlocal

set "MONGO_BIN=E:\mongodb\mongodb-win32-x86_64-windows-8.0.4\bin\mongod.exe"
set "MONGO_DATA=E:\mongodb\data"
set "EMULATOR_DIR=E:\mongodb\firebase-emulator"
set "FIREBASE_PROJECT=pokemon-auto-chess-local-6b967"
set "REPO=%~dp0"

if not exist "%REPO%package.json" (
  echo ERROR: package.json not found next to this script.
  echo Keep start-offline.cmd in the repository root.
  pause
  exit /b 1
)

echo Starting MongoDB...
start "mongo (27017)" "%MONGO_BIN%" --dbpath "%MONGO_DATA%" --port 27017 --bind_ip 127.0.0.1

echo Starting Firebase Auth emulator...
REM --import/--export-on-exit make the emulator persist its accounts to disk.
REM WITHOUT these the emulator keeps users in memory only, so every restart wipes
REM them and you have to register again (leaving an orphan record in MongoDB each
REM time). The data dir must exist before --import runs.
if not exist "%EMULATOR_DIR%\data" mkdir "%EMULATOR_DIR%\data"
start "firebase-auth (9099)" /D "%EMULATOR_DIR%" cmd /k "node_modules\.bin\firebase.cmd emulators:start --only auth --project %FIREBASE_PROJECT% --import data --export-on-exit data"

echo Waiting for the database and emulator to accept connections...
timeout /t 10 /nobreak >nul

echo Starting Pokemon Auto Chess...
start "pokemon-auto-chess (9000)" /D "%REPO%" cmd /k "npm run dev"

echo.
echo All three windows are starting. Give the game server a few seconds,
echo then open:  http://localhost:9000/
echo.
pause

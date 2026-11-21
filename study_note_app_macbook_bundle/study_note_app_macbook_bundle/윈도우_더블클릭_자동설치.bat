@echo off
chcp 65001 >nul
title [AI 스터디 노트 앱] 윈도우 원클릭 자동 조립 및 실행기 (.exe / .apk)

echo ============================================================================
echo  🚀 [윈도우 전용] 더블클릭 한 번으로 프로젝트 조립 + 실행(.exe) / APK 생성
echo ============================================================================
echo.

set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup_windows.ps1"

echo.
echo ============================================================================
echo  원하시는 작업을 아래 번호로 선택해 주세요:
echo    [1] 지금 바로 내 윈도우 PC 화면에서 스터디 노트 앱(.exe) 켜기
echo    [2] 갤럭시 탭/안드로이드용 설치 파일(.apk)을 내 바탕화면에 만들기
echo    [3] 종료하기
echo ============================================================================
set /p CHOICE="번호를 입력하고 엔터(Enter)를 치세요 (1, 2, 3): "

if "%CHOICE%"=="1" (
    cd /d "%SCRIPT_DIR%study_note_app"
    flutter run -d windows
    pause
) else if "%CHOICE%"=="2" (
    cd /d "%SCRIPT_DIR%study_note_app"
    echo.
    echo 📦 갤럭시 탭용 APK 설치 파일을 만드는 중입니다 (약 2~3분 소요)...
    call flutter build apk --release
    if exist "build\app\outputs\flutter-apk\app-release.apk" (
        copy /Y "build\app\outputs\flutter-apk\app-release.apk" "%USERPROFILE%\Desktop\StudyNote_App_Install.apk"
        echo.
        echo 🎉 성공! 윈도우 [바탕화면]에 'StudyNote_App_Install.apk' 파일이 생성되었습니다!
        echo    이 파일을 카카오톡이나 USB로 갤럭시 탭에 보내 터치하면 바로 설치됩니다.
    ) else (
        echo ⚠️ APK 생성을 위해 Android Studio SDK가 필요합니다.
    )
    pause
)

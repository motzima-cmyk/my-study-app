# ==============================================================================
# [Windows 전용] AI 태블릿 스터디 노트 앱 (study_note_app) 원클릭 자동 설치 스크립트
# 사용법:
#   1) 다운로드한 모든 코드 파일들과 이 파일(setup_windows.ps1)을 같은 폴더에 둡니다.
#   2) setup_windows.ps1 파일 위에서 마우스 우클릭 -> [PowerShell에서 실행]을 누르거나,
#      VS Code 터미널(PowerShell)에서 아래 명령어를 입력합니다:
#      powershell -ExecutionPolicy Bypass -File .\setup_windows.ps1
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

$ProjectName = "study_note_app"
$OrgDomain = "com.studynote"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = (Get-Location).Path
}
$ProjectDir = Join-Path $ScriptDir $ProjectName
$DownloadsDir = Join-Path $HOME "Downloads"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " 🚀 [StudyNote App] Windows 원클릭 프로젝트 생성 및 파일 자동 배치 시작" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "📂 작업 기준 폴더: $ScriptDir"
Write-Host ""

# 1. Flutter SDK 설치 여부 확인
$FlutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
if ($null -ne $FlutterCmd) {
    Write-Host "✅ [1/5] Flutter SDK가 확인되었습니다." -ForegroundColor Green
    $HasFlutter = $true
} else {
    Write-Host "⚠️  [1/5] 현재 컴퓨터에서 'flutter' 명령어를 찾을 수 없습니다." -ForegroundColor Yellow
    Write-Host "   👉 아직 Flutter를 설치하지 않으셨다면 https://docs.flutter.dev/install/with-vs-code 를 참고해 설치해 주세요."
    Write-Host "   👉 지금은 폴더 구조 생성과 14개 파일 자동 배치를 먼저 완료해 드립니다!"
    $HasFlutter = $false
}
Write-Host ""

# 2. Flutter 프로젝트 스캐폴딩 생성
$AndroidCheckPath = Join-Path $ProjectDir "android"
if ($HasFlutter -and -not (Test-Path $AndroidCheckPath)) {
    Write-Host "🛠️  [2/5] '$ProjectName' 기본 Flutter 프로젝트를 생성합니다..." -ForegroundColor Cyan
    Push-Location $ScriptDir
    flutter create --org $OrgDomain $ProjectName
    Pop-Location
} else {
    Write-Host "📁 [2/5] '$ProjectName' 디렉토리 구조를 준비합니다..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $ProjectDir | Out-Null
}

# 필수 하위 폴더 생성 보장
$SubDirs = @(
    "lib",
    "test",
    "ios\Runner",
    "android\app\src\main\kotlin\com\studynote\study_note_app",
    "fastlane"
)
foreach ($Sub in $SubDirs) {
    $FullSubPath = Join-Path $ProjectDir $Sub
    New-Item -ItemType Directory -Force -Path $FullSubPath | Out-Null
}
Write-Host ""

# 3. 파일 자동 복사 헬퍼 함수 (현재 폴더 또는 Downloads 폴더에서 탐색)
function Copy-StudyFile {
    param (
        [string]$FileName,
        [string]$TargetRelPath
    )
    $SourceInCurrent = Join-Path $ScriptDir $FileName
    $SourceInDownloads = Join-Path $DownloadsDir $FileName
    $DestPath = Join-Path $ProjectDir $TargetRelPath

    if (Test-Path $SourceInCurrent) {
        Copy-Item -Path $SourceInCurrent -Destination $DestPath -Force
        Write-Host "   ✔ 배치 완료: $FileName  -->  $ProjectName\$TargetRelPath" -ForegroundColor Green
    } elseif (Test-Path $SourceInDownloads) {
        Copy-Item -Path $SourceInDownloads -Destination $DestPath -Force
        Write-Host "   ✔ 배치 완료 (다운로드 폴더에서 찾음): $FileName  -->  $ProjectName\$TargetRelPath" -ForegroundColor Green
    } else {
        Write-Host "   ⚠️  파일을 찾지 못함: $FileName (스크립트와 같은 폴더 또는 다운로드 폴더에 넣어주세요)" -ForegroundColor Yellow
    }
}

Write-Host "📦 [3/5] 생성된 소스 코드 및 설정 파일 14개를 알맞은 폴더에 자동 배치합니다..." -ForegroundColor Cyan

# 루트 설정 및 스키마 파일
Copy-StudyFile -FileName "pubspec.yaml" -TargetRelPath "pubspec.yaml"
Copy-StudyFile -FileName "README.md" -TargetRelPath "README.md"
Copy-StudyFile -FileName "supabase_study_sync_schema.sql" -TargetRelPath "supabase_study_sync_schema.sql"
Copy-StudyFile -FileName "Fastfile" -TargetRelPath "fastlane\Fastfile"

# lib\ 폴더 핵심 Dart 파일 7개
Copy-StudyFile -FileName "main.dart" -TargetRelPath "lib\main.dart"
Copy-StudyFile -FileName "adaptive_study_workspace.dart" -TargetRelPath "lib\adaptive_study_workspace.dart"
Copy-StudyFile -FileName "study_models.dart" -TargetRelPath "lib\study_models.dart"
Copy-StudyFile -FileName "study_services.dart" -TargetRelPath "lib\study_services.dart"
Copy-StudyFile -FileName "study_sync_repository.dart" -TargetRelPath "lib\study_sync_repository.dart"
Copy-StudyFile -FileName "study_workspace_widgets.dart" -TargetRelPath "lib\study_workspace_widgets.dart"
Copy-StudyFile -FileName "real_device_audio_adapter.dart" -TargetRelPath "lib\real_device_audio_adapter.dart"

# test\ 폴더 단위 및 위젯 테스트 파일
Copy-StudyFile -FileName "widget_test.dart" -TargetRelPath "test\widget_test.dart"

# 네이티브 스타일러스 & 캘린더 브리지 파일 (iPadOS / Android)
Copy-StudyFile -FileName "AppDelegate.swift" -TargetRelPath "ios\Runner\AppDelegate.swift"
Copy-StudyFile -FileName "MainActivity.kt" -TargetRelPath "android\app\src\main\kotlin\com\studynote\study_note_app\MainActivity.kt"

Write-Host ""

# 4. 패키지 설치 및 테스트 실행
if ($HasFlutter) {
    Write-Host "📥 [4/5] 필요한 패키지(flutter pub get)를 자동으로 내려받습니다..." -ForegroundColor Cyan
    Push-Location $ProjectDir
    flutter pub get
    Write-Host ""

    Write-Host "🧪 [5/5] 자동 기능 검증 테스트(flutter test)를 실행합니다..." -ForegroundColor Cyan
    flutter test
    Pop-Location
} else {
    Write-Host "⏭️  [4/5] Flutter 설치 후 '$ProjectName' 폴더에서 'flutter pub get'을 실행해 주세요." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " 🎉 모든 파일 배치가 완료되었습니다!" -ForegroundColor Green
Write-Host " 📂 프로젝트 위치: $ProjectDir"
Write-Host ""
Write-Host " ▶ 바로 앱을 켜보려면 터미널에 아래 명령어를 입력하세요:"
Write-Host "    cd `"$ProjectDir`""
Write-Host "    flutter run"
Write-Host ""
Write-Host " ▶ Gemini AI 키를 함께 연결해 실행하려면:"
Write-Host "    flutter run --dart-define=GEMINI_API_KEY=여기에_발급받은_키_입력"
Write-Host "==================================================================" -ForegroundColor Cyan

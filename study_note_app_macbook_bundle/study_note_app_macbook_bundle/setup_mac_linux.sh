#!/usr/bin/env bash
# ==============================================================================
# [맥북 초보자 전용] AI 태블릿 스터디 노트 앱 (study_note_app) 올인원 자동 설치기
# ------------------------------------------------------------------------------
# 이 스크립트가 자동으로 해 주는 일:
#   1) Flutter가 안 깔려 있으면 -> 자동으로 Flutter를 다운로드하고 경로(PATH)까지 등록!
#   2) CocoaPods가 안 깔려 있으면 -> 자동으로 내 계정에 설치하고 경로 등록!
#   3) study_note_app 폴더를 만들고 14개 코드 파일을 정확한 위치에 자동 배치!
#   4) 아이패드 iOS 최소 버전(15.0) 및 마이크·캘린더 권한(Info.plist) 자동 입력!
#   5) 패키지 설치(flutter pub get) 후 마지막에 Xcode 화면을 자동으로 띄워줌!
# ==============================================================================

set -e

PROJECT_NAME="study_note_app"
ORG_DOMAIN="com.studynote"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/${PROJECT_NAME}"

echo "=================================================================="
echo " 🍎 [맥북 -> 아이패드] 완전 자동 설치를 시작합니다!"
echo "=================================================================="
echo "📂 현재 작업 폴더: ${SCRIPT_DIR}"
echo ""

# ------------------------------------------------------------------------------
# [단계 1] Xcode 설치 확인
# ------------------------------------------------------------------------------
if [ -d "/Applications/Xcode.app" ]; then
  echo "✅ [1/6] 맥북에 Xcode가 설치되어 있습니다."
  CURRENT_XCODE_PATH="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$CURRENT_XCODE_PATH" != *"/Applications/Xcode.app"* ]]; then
    echo "🔐 Xcode 개발자 도구 연결을 위해 맥북 로그인 암호가 필요할 수 있습니다."
    echo "   (화면에 글자나 별표가 안 보여도 평소 맥북 암호를 치고 엔터를 누르세요)"
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer || true
    sudo xcodebuild -license accept || true
  fi
else
  echo "⚠️  [1/6] '/Applications/Xcode.app'을 아직 찾지 못했습니다."
  echo "   👉 만약 App Store에서 Xcode를 아직 안 받으셨다면 설치를 완료해 주세요."
fi
echo ""

# ------------------------------------------------------------------------------
# [단계 2] Flutter SDK 확인 및 미설치 시 자동 다운로드!
# ------------------------------------------------------------------------------
for candidate in \
  "$HOME/development/flutter/bin" \
  "$HOME/flutter/bin" \
  "$HOME/Documents/flutter/bin" \
  "$HOME/Downloads/flutter/bin" \
  "/opt/homebrew/Caskroom/flutter/latest/flutter/bin" \
  "/usr/local/Caskroom/flutter/latest/flutter/bin"; do
  if [ -x "$candidate/flutter" ]; then
    export PATH="$candidate:$PATH"
    break
  fi
done

if ! command -v flutter >/dev/null 2>&1; then
  echo "📥 [2/6] 맥북에 아직 Flutter가 설치되어 있지 않아 자동으로 다운로드합니다..."
  echo "   (최초 1회 약 2~4분 정도 걸립니다. 잠시만 기다려 주세요!)"
  mkdir -p "$HOME/development"
  if [ ! -d "$HOME/development/flutter" ]; then
    git clone https://github.com/flutter/flutter.git -b stable "$HOME/development/flutter"
  fi
  export PATH="$HOME/development/flutter/bin:$PATH"
  if ! grep -q "development/flutter/bin" "$HOME/.zshrc" 2>/dev/null; then
    echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> "$HOME/.zshrc"
  fi
  echo "✅ Flutter 자동 설치 및 경로 등록 완료!"
else
  echo "✅ [2/6] Flutter SDK 확인 완료: $(flutter --version | head -n 1)"
fi
echo ""

# ------------------------------------------------------------------------------
# [단계 3] CocoaPods(pod) 확인 및 미설치 시 자동 설치!
# ------------------------------------------------------------------------------
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if command -v ruby >/dev/null 2>&1; then
  USER_GEM_BIN="$(ruby -e 'puts Gem.user_dir' 2>/dev/null)/bin"
  if [ -d "$USER_GEM_BIN" ]; then
    export PATH="$USER_GEM_BIN:$PATH"
  fi
fi

if ! command -v pod >/dev/null 2>&1; then
  echo "📥 [3/6] 아이패드 플러그인 연결 도구(CocoaPods)를 자동 설치합니다..."
  if command -v brew >/dev/null 2>&1; then
    brew install cocoapods || true
  fi
  if ! command -v pod >/dev/null 2>&1; then
    gem install cocoapods --user-install --no-document || true
    USER_GEM_BIN="$(ruby -e 'puts Gem.user_dir' 2>/dev/null)/bin"
    export PATH="$USER_GEM_BIN:$PATH"
    if ! grep -q "$USER_GEM_BIN" "$HOME/.zshrc" 2>/dev/null; then
      echo "export PATH=\"$USER_GEM_BIN:\$PATH\"" >> "$HOME/.zshrc"
    fi
  fi
else
  echo "✅ [3/6] CocoaPods 확인 완료: $(pod --version 2>/dev/null || echo 'installed')"
fi
echo ""

# ------------------------------------------------------------------------------
# [단계 4] study_note_app 프로젝트 생성 및 14개 파일 자동 배치
# ------------------------------------------------------------------------------
if [ ! -d "${PROJECT_DIR}/ios" ]; then
  echo "🛠️  [4/6] '${PROJECT_NAME}' 아이패드용 앱 폴더를 생성합니다..."
  (cd "${SCRIPT_DIR}" && flutter create --org "${ORG_DOMAIN}" --platforms=ios,android,macos "${PROJECT_NAME}")
else
  echo "✅ [4/6] 기존 '${PROJECT_NAME}' 앱 폴더를 사용합니다."
fi

mkdir -p "${PROJECT_DIR}/lib"
mkdir -p "${PROJECT_DIR}/test"
mkdir -p "${PROJECT_DIR}/ios/Runner"
mkdir -p "${PROJECT_DIR}/android/app/src/main/kotlin/com/studynote/study_note_app"
mkdir -p "${PROJECT_DIR}/fastlane"

copy_file_to_target() {
  local filename="$1"
  local target_rel_path="$2"
  local dest_path="${PROJECT_DIR}/${target_rel_path}"

  if [ -f "${SCRIPT_DIR}/${filename}" ]; then
    cp -f "${SCRIPT_DIR}/${filename}" "${dest_path}"
    echo "   ✔ 배치 완료: ${filename}  -->  ${PROJECT_NAME}/${target_rel_path}"
  elif [ -f "${HOME}/Downloads/study_note_app_macbook_bundle/${filename}" ]; then
    cp -f "${HOME}/Downloads/study_note_app_macbook_bundle/${filename}" "${dest_path}"
    echo "   ✔ 배치 완료: ${filename}  -->  ${PROJECT_NAME}/${target_rel_path}"
  elif [ -f "${HOME}/Downloads/${filename}" ]; then
    cp -f "${HOME}/Downloads/${filename}" "${dest_path}"
    echo "   ✔ 배치 완료: ${filename}  -->  ${PROJECT_NAME}/${target_rel_path}"
  else
    echo "   ⚠️  파일 미발견: ${filename}"
  fi
}

echo ""
echo "📦 코드 파일 14개를 정확한 폴더에 넣는 중..."
copy_file_to_target "pubspec.yaml" "pubspec.yaml"
copy_file_to_target "README.md" "README.md"
copy_file_to_target "supabase_study_sync_schema.sql" "supabase_study_sync_schema.sql"
copy_file_to_target "Fastfile" "fastlane/Fastfile"

copy_file_to_target "main.dart" "lib/main.dart"
copy_file_to_target "adaptive_study_workspace.dart" "lib/adaptive_study_workspace.dart"
copy_file_to_target "study_models.dart" "lib/study_models.dart"
copy_file_to_target "study_services.dart" "lib/study_services.dart"
copy_file_to_target "study_sync_repository.dart" "lib/study_sync_repository.dart"
copy_file_to_target "study_workspace_widgets.dart" "lib/study_workspace_widgets.dart"
copy_file_to_target "real_device_audio_adapter.dart" "lib/real_device_audio_adapter.dart"

copy_file_to_target "widget_test.dart" "test/widget_test.dart"
copy_file_to_target "AppDelegate.swift" "ios/Runner/AppDelegate.swift"
copy_file_to_target "MainActivity.kt" "android/app/src/main/kotlin/com/studynote/study_note_app/MainActivity.kt"
echo ""

# ------------------------------------------------------------------------------
# [단계 5] 아이패드 iOS 버전(15.0) 및 마이크·캘린더 권한(Info.plist) 자동 설정
# ------------------------------------------------------------------------------
echo "🔐 [5/6] 아이패드 iOS 최소 버전(15.0) 및 마이크·캘린더 권한을 자동 설정합니다..."

INFO_PLIST="${PROJECT_DIR}/ios/Runner/Info.plist"
if [ -f "${INFO_PLIST}" ] && [ -x "/usr/libexec/PlistBuddy" ]; then
  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string '강의 음성을 녹음하고 필기 타임스탬프와 동기화하기 위해 마이크 권한이 필요합니다.'" "${INFO_PLIST}" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription '강의 음성을 녹음하고 필기 타임스탬프와 동기화하기 위해 마이크 권한이 필요합니다.'" "${INFO_PLIST}"

  /usr/libexec/PlistBuddy -c "Add :NSCalendarsFullAccessUsageDescription string 'AI 스터디 플래너의 오늘 학습 할당량과 뽀모도로 시간표를 아이패드 캘린더에 등록하기 위해 권한이 필요합니다.'" "${INFO_PLIST}" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :NSCalendarsFullAccessUsageDescription 'AI 스터디 플래너의 오늘 학습 할당량과 뽀모도로 시간표를 아이패드 캘린더에 등록하기 위해 권한이 필요합니다.'" "${INFO_PLIST}"

  /usr/libexec/PlistBuddy -c "Add :NSCalendarsUsageDescription string 'AI 스터디 플래너의 학습 시간표를 아이패드 캘린더에 등록하기 위해 권한이 필요합니다.'" "${INFO_PLIST}" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :NSCalendarsUsageDescription 'AI 스터디 플래너의 학습 시간표를 아이패드 캘린더에 등록하기 위해 권한이 필요합니다.'" "${INFO_PLIST}"
fi

PBXPROJ="${PROJECT_DIR}/ios/Runner.xcodeproj/project.pbxproj"
if [ -f "${PBXPROJ}" ]; then
  sed -i '' 's/IPHONEOS_DEPLOYMENT_TARGET = 1[1234]\.0;/IPHONEOS_DEPLOYMENT_TARGET = 15.0;/g' "${PBXPROJ}" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# [단계 6] 패키지 다운로드 및 Xcode 자동 실행
# ------------------------------------------------------------------------------
echo "📥 [6/6] 앱 부품 패키지(flutter pub get)를 다운로드합니다..."
(cd "${PROJECT_DIR}" && flutter pub get)

PODFILE="${PROJECT_DIR}/ios/Podfile"
if [ -f "${PODFILE}" ]; then
  sed -i '' "s/# platform :ios, '[0-9.]*'/platform :ios, '15.0'/g" "${PODFILE}" 2>/dev/null || true
  sed -i '' "s/platform :ios, '1[1234]\.0'/platform :ios, '15.0'/g" "${PODFILE}" 2>/dev/null || true
fi

echo ""
echo "=================================================================="
echo " 🎉 축하합니다! 맥북에서의 모든 파일 조립과 설정이 끝났습니다!"
echo " 📂 완성된 앱 폴더: ${PROJECT_DIR}"
echo "=================================================================="
echo ""
echo " 👉 이제 3초 뒤에 Xcode 창이 자동으로 열립니다!"
echo "    Xcode가 열리면 설명서의 [5단계: 내 무료 Apple ID 선택하고 재생(▶) 버튼 누르기]만 따라 하세요!"
echo ""

if [ -d "${PROJECT_DIR}/ios/Runner.xcworkspace" ]; then
  open "${PROJECT_DIR}/ios/Runner.xcworkspace" || true
elif [ -d "${PROJECT_DIR}/ios/Runner.xcodeproj" ]; then
  open "${PROJECT_DIR}/ios/Runner.xcodeproj" || true
fi

# AI 태블릿 스터디 노트 (iPad 4:3 & Android Tablet 16:10)

자유노트(FreeNotes) 스타일의 **실시간 PDF 필기·녹음 타임스탬프 동기화**와 **Gemini 2.5 Flash 멀티모달 학습 비서**를 결합한 크로스 플랫폼 태블릿 학습 앱입니다.

## 1. 프로젝트 파일 구조

```text
adaptive_tablet_study_note/
├── pubspec.yaml                       # 태블릿 필수 의존성 패키지 및 권한 설정 명세
├── supabase_study_sync_schema.sql     # Supabase PostgreSQL + Realtime CRDT 초기화 SQL
├── lib/
│   ├── main.dart                      # 태블릿 회전 정책, Firebase Core, Supabase 안전 부트스트랩
│   ├── adaptive_study_workspace.dart  # 반응형 2·3단 워크스페이스, 필기·가림막·오디오·AI 통합 엔진
│   └── real_device_audio_adapter.dart # record(마이크 녹음) + just_audio(오디오북 클리핑) 하드웨어 어댑터
└── test/
    └── widget_test.dart               # 레이아웃 정책, 필기-음성 싱크, SM-2 복습, CRDT 병합 자동 테스트
```

## 2. 핵심 구현 기능 요약

| 영역 | 구현된 세부 기능 |
| :--- | :--- |
| **반응형 태블릿 UI** | • iPad(4:3, `68:32` 2단) 및 안드로이드 태블릿(16:10, `18:54:28` 3단) 자동 전환 (`TabletLayoutPolicy`)<br>• 왼손 필기 모드(사이드바 좌측 이동), 시험 집중 모드(`75:25`), Split View 화면비 시뮬레이터, 다크 모드 전환 |
| **PDF & 필기 동기화** | • `NormalizedStroke` 페이지 상대 좌표(`0.0~1.0`) 기반 해상도 무관 필기 및 합본 PDF 내보내기(Flatten Export)<br>• 오프라인 우선 로컬 SQLite(`sqflite`) + Supabase Realtime 양방향 합집합·Tombstone 병합(`StudySyncRepository`) |
| **강의 녹음 & 오디오북** | • 필기 획 탭 시 해당 녹음 시각으로 즉시 점프 재생 및 실시간 필기 리플레이 애니메이션<br>• Gemini 음성 전사 대본(`AudioTranscriptSegment`) 키워드 검색 시 발화 구간 + 필기 획 동시 하이라이트<br>• 매칭 구간만 무공백 연속 재생하는 **키워드 하이라이트 오디오북 플레이리스트** 및 데시벨 피크 파형 미니맵 |
| **가림막 & 손글씨 AI 채점** | • 교수님이 정답을 말하기 0.6초 전에 자동 일시정지하는 **음성 빈칸 퀴즈 모드**<br>• 애플펜슬·S펜으로 가림막 위에 직접 답안을 적으면 Gemini Vision이 OCR 및 의미 기반으로 채점하는 **손글씨 빈칸 채점 모드**<br>• 채점 점수로 복습 주기를 자동 계산하는 **에빙하우스(SM-2) 스마트 복습 스케줄러** 및 **D-Day 타임어택 모의고사** |
| **펜슬 하드웨어 & 판서** | • 애플펜슬 더블탭(`MethodChannel`) 및 갤럭시 S펜 측면 버튼(`kSecondaryStylusButton`) 도구 즉시 스왑<br>• 강의 중 촬영한 칠판 판서 사진을 현재 PDF 여백에 드래그 가능한 스티커 노트로 부착(`BoardPhotoStickerNote`) |

## 3. 빠른 시작 및 실기기 실행 방법

### 1단계: 패키지 설치
```bash
flutter pub get
```

### 2단계: Supabase 테이블 및 Realtime 활성화
1. Supabase 프로젝트 대시보드의 **SQL Editor**를 엽니다.
2. `supabase_study_sync_schema.sql` 파일 내용을 붙여넣고 실행(Run)합니다.

### 3단계: 아이패드 / 갤럭시 탭 실기기 빌드 및 실행
```bash
flutter run \
  --dart-define=SUPABASE_URL=https://your-project.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your-anon-key
```
> 환경변수를 생략하고 `flutter run`만 실행해도 로컬 SQLite(`sqflite`) 및 온디바이스 폴백 모드로 모든 기능을 즉시 테스트할 수 있습니다.

### 4단계: 단위 및 위젯 테스트 실행
```bash
flutter test test/widget_test.dart
```

/// ============================================================================
/// AI 태블릿 스터디 노트 — 모듈 통합 배럴(Barrel) 익스포트 파일
/// ============================================================================
/// 기존에 단일 파일로 작성되었던 전체 코드가 아래 4개 역할별 모듈로 분리되었습니다:
/// 1. study_models.dart            (Models: 필기·가림막·SM-2·오디오북·플래너·레이아웃 정책)
/// 2. study_services.dart          (Services: Gemini 2.5 Flash·PDF 합본·알림·캘린더 .ics)
/// 3. study_sync_repository.dart   (Repositories: 로컬 SQLite + Supabase Realtime CRDT 동기화)
/// 4. study_workspace_widgets.dart (Widgets & Painters: 반응형 2·3단 UI·듀얼 PDF·서브노트·6종 CustomPainter)
///
/// 이 파일(adaptive_study_workspace.dart)을 import하면 4개 모듈이 모두 자동으로 노출되므로
/// main.dart, real_device_audio_adapter.dart, widget_test.dart와 100% 하위 호환됩니다.
library adaptive_study_workspace;

export 'study_models.dart';
export 'study_services.dart';
export 'study_sync_repository.dart';
export 'study_workspace_widgets.dart';

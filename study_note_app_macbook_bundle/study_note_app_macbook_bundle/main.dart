import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'adaptive_study_workspace.dart';

/// ============================================================================
/// AI 태블릿 스터디 노트 (iPad 4:3 & Android Tablet 16:10) 메인 엔트리포인트
/// ============================================================================
/// 실행 예시:
/// flutter run \
///   --dart-define=SUPABASE_URL=https://your-project.supabase.co \
///   --dart-define=SUPABASE_ANON_KEY=your-anon-key
///
/// 환경변수가 설정되지 않은 로컬/오프라인 상태에서도 앱이 크래시 없이
/// 로컬 SQLite(sqflite) + 온디바이스 Gemini 폴백 모드로 즉시 부팅됩니다.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. 아이패드 및 안드로이드 태블릿 가로/세로 회전 허용 (가로 모드 기본 최적화)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // 2. Firebase Core 초기화 (firebase_ai Gemini 2.5 Flash 연동용)
  try {
    await Firebase.initializeApp();
    debugPrint('[Bootstrap] Firebase Core 초기화 완료 (Gemini 2.5 Flash 활성화)');
  } catch (e) {
    debugPrint(
      '[Bootstrap] Firebase 설정 파일(google-services.json / GoogleService-Info.plist) 미감지 — 오프라인 휴리스틱/폴백 모드로 동작합니다: $e',
    );
  }

  // 3. Supabase Realtime 초기화 (아이패드 <-> 안드로이드 태블릿 실시간 동기화용)
  const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );
  const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabaseAnonKey,
      );
      debugPrint('[Bootstrap] Supabase Realtime 동기화 엔진 연결 완료');
    } catch (e) {
      debugPrint('[Bootstrap] Supabase 초기화 실패 — 로컬 SQLite 오프라인 우선 모드로 동작: $e');
    }
  } else {
    debugPrint(
      '[Bootstrap] SUPABASE_URL 미지정 — 로컬 SQLite(sqflite) 단독 저장 모드로 시작합니다.',
    );
  }

  runApp(const AdaptiveStudyNoteApp());
}

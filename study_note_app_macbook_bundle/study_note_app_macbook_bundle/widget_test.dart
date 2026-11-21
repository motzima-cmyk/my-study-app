import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'adaptive_study_workspace.dart';

/// ============================================================================
/// AI 태블릿 스터디 노트 — 핵심 도메인·동기화·도형보정·듀얼PDF·AI플래너 단위 및 위젯 테스트 스위트
/// ============================================================================
/// 실행 명령어:
/// flutter test test/widget_test.dart
void main() {
  group('1. TabletLayoutPolicy 화면 비율(4:3 vs 16:10) 자동 전환 검증', () {
    test('iPad 가로 모드(4:3, 1024x768)에서는 폴더 창을 숨기고 68:32 2단 레이아웃을 반환한다', () {
      const policy = TabletLayoutPolicy(
        width: 1024,
        height: 768,
        isExamFocusMode: false,
        isLeftHanded: false,
      );

      expect(policy.aspectRatio, closeTo(1.333, 0.01));
      expect(policy.showPersistentFolderPane, isFalse);
      expect(policy.folderFlex, equals(0));
      expect(policy.canvasFlex, equals(68));
      expect(policy.sidebarFlex, equals(32));
    });

    test('안드로이드 태블릿 가로 모드(16:10, 1280x800)에서는 18:54:28 3단 레이아웃을 반환한다', () {
      const policy = TabletLayoutPolicy(
        width: 1280,
        height: 800,
        isExamFocusMode: false,
        isLeftHanded: false,
      );

      expect(policy.aspectRatio, closeTo(1.6, 0.01));
      expect(policy.showPersistentFolderPane, isTrue);
      expect(policy.folderFlex, equals(18));
      expect(policy.canvasFlex, equals(54));
      expect(policy.sidebarFlex, equals(28));
    });

    test('시험 집중 모드 활성화 시 화면 비율과 무관하게 75:25 집중 2단으로 전환된다', () {
      const policy = TabletLayoutPolicy(
        width: 1280,
        height: 800,
        isExamFocusMode: true,
        isLeftHanded: false,
      );

      expect(policy.showPersistentFolderPane, isFalse);
      expect(policy.canvasFlex, equals(75));
      expect(policy.sidebarFlex, equals(25));
    });
  });

  group('2. NormalizedStroke 오디오 타임스탬프 교차 검증 및 히트 테스트', () {
    final sampleStroke = NormalizedStroke(
      strokeId: 's_test_28s',
      tool: DrawingTool.pen,
      color: const Color(0xFF1565C0),
      normalizedWidth: 0.004,
      recordingSessionId: 'rec_01',
      audioStartMs: 28000,
      audioEndMs: 31000,
      points: [
        const NormalizedPoint(x: 0.10, y: 0.40, audioOffsetMs: 28000),
        const NormalizedPoint(x: 0.30, y: 0.40, audioOffsetMs: 29500),
        const NormalizedPoint(x: 0.50, y: 0.40, audioOffsetMs: 31000),
      ],
    );

    test('전사 세그먼트 구간(20000~39999ms)과 필기 획의 시간 구간 교차를 정확히 감지한다', () {
      expect(sampleStroke.overlapsTimeRange(20000, 39999), isTrue);
      expect(sampleStroke.overlapsTimeRange(0, 19999), isFalse);
      expect(sampleStroke.overlapsTimeRange(40000, 60000), isFalse);
    });

    test('획 위를 탭했을 때 hitTest가 반경 내 좌표를 정확히 판별한다', () {
      expect(sampleStroke.hitTest(const Offset(0.30, 0.405)), isTrue);
      expect(sampleStroke.hitTest(const Offset(0.85, 0.85)), isFalse);
    });
  });

  group('3. EbbinghausReviewSchedule (SuperMemo SM-2) 간격 반복 알고리즘 검증', () {
    test('손글씨 채점 고득점(96점) 연속 획득 시 복습 주기가 1일 -> 3일 -> 8일로 늘어난다', () {
      final schedule = EbbinghausReviewSchedule();

      schedule.recordAttemptScore(96);
      expect(schedule.repetitionCount, equals(1));
      expect(schedule.intervalDays, equals(1));

      schedule.recordAttemptScore(96);
      expect(schedule.repetitionCount, equals(2));
      expect(schedule.intervalDays, equals(3));

      schedule.recordAttemptScore(96);
      expect(schedule.repetitionCount, equals(3));
      expect(schedule.intervalDays, greaterThanOrEqualTo(7));
    });

    test('오답 또는 저득점(45점) 발생 시 복습 횟수가 0으로 초기화되고 즉시 재시험 상태(isDueNow)가 된다', () {
      final schedule = EbbinghausReviewSchedule(
        repetitionCount: 2,
        intervalDays: 3,
        lastScore: 95,
      );

      schedule.recordAttemptScore(45);
      expect(schedule.repetitionCount, equals(0));
      expect(schedule.intervalDays, equals(0));
      expect(schedule.isDueNow, isTrue);
    });
  });

  group('4. PageAnnotationSnapshot CRDT 병합(아이패드 <-> 안드로이드 태블릿) 검증', () {
    test('양쪽 기기에서 추가된 필기 획을 합집합으로 병합하고 삭제된 ID(Tombstone)를 양쪽에서 제거한다', () {
      final strokeA = NormalizedStroke(
        strokeId: 'stroke_ipad_1',
        tool: DrawingTool.pen,
        color: Colors.blue,
        normalizedWidth: 0.004,
        points: [const NormalizedPoint(x: 0.1, y: 0.1)],
      );
      final strokeB = NormalizedStroke(
        strokeId: 'stroke_android_2',
        tool: DrawingTool.highlighter,
        color: Colors.yellow,
        normalizedWidth: 0.02,
        points: [const NormalizedPoint(x: 0.2, y: 0.2)],
      );

      final ipadSnap = PageAnnotationSnapshot(
        docId: 'doc_bio',
        pageNumber: 14,
        strokes: [strokeA],
        masks: const [],
        deletedIds: <String>{},
      );

      final androidSnap = PageAnnotationSnapshot(
        docId: 'doc_bio',
        pageNumber: 14,
        strokes: [strokeA, strokeB],
        masks: const [],
        deletedIds: <String>{'stroke_ipad_1'},
      );

      final merged = ipadSnap.mergeWith(androidSnap);
      expect(merged.strokes.length, equals(1));
      expect(merged.strokes.single.strokeId, equals('stroke_android_2'));
      expect(merged.deletedIds.contains('stroke_ipad_1'), isTrue);
    });
  });

  group('5. 도형 자동 보정(Hold-to-Snap: trySnapPointsToCleanShape) 검증', () {
    test('약간 흔들린 수평 밑줄 궤적을 반듯한 수평 밑줄로 스냅하고 모든 y 좌표를 수평 정렬한다', () {
      final wavyUnderline = NormalizedStroke(
        strokeId: 's_wavy_line',
        tool: DrawingTool.highlighter,
        color: const Color(0x66FFEE58),
        normalizedWidth: 0.02,
        audioStartMs: 12000,
        points: [
          const NormalizedPoint(x: 0.10, y: 0.300, audioOffsetMs: 12000),
          const NormalizedPoint(x: 0.22, y: 0.304, audioOffsetMs: 12100),
          const NormalizedPoint(x: 0.35, y: 0.297, audioOffsetMs: 12200),
          const NormalizedPoint(x: 0.48, y: 0.303, audioOffsetMs: 12300),
          const NormalizedPoint(x: 0.62, y: 0.299, audioOffsetMs: 12400),
          const NormalizedPoint(x: 0.75, y: 0.308, audioOffsetMs: 12500),
        ],
      );

      final snappedLabel = wavyUnderline.trySnapPointsToCleanShape();
      expect(snappedLabel, equals('반듯한 수평 밑줄'));
      expect(wavyUnderline.points.length, greaterThanOrEqualTo(10));

      for (final pt in wavyUnderline.points) {
        expect(pt.y, closeTo(0.300, 0.0001));
      }
      expect(wavyUnderline.points.first.x, closeTo(0.10, 0.001));
      expect(wavyUnderline.points.last.x, closeTo(0.75, 0.001));
    });

    test('네 모서리를 따라 그린 닫힌 사각형 궤적을 반듯한 직사각형 박스로 자동 보정한다', () {
      final roughBox = NormalizedStroke(
        strokeId: 's_rough_rect',
        tool: DrawingTool.pen,
        color: const Color(0xFF1565C0),
        normalizedWidth: 0.004,
        points: [
          const NormalizedPoint(x: 0.20, y: 0.20),
          const NormalizedPoint(x: 0.40, y: 0.20),
          const NormalizedPoint(x: 0.60, y: 0.20),
          const NormalizedPoint(x: 0.60, y: 0.35),
          const NormalizedPoint(x: 0.60, y: 0.50),
          const NormalizedPoint(x: 0.40, y: 0.50),
          const NormalizedPoint(x: 0.20, y: 0.50),
          const NormalizedPoint(x: 0.20, y: 0.35),
          const NormalizedPoint(x: 0.205, y: 0.205),
        ],
      );

      final snappedLabel = roughBox.trySnapPointsToCleanShape();
      expect(snappedLabel, equals('반듯한 직사각형 박스'));
      expect(roughBox.points.first.x, closeTo(0.20, 0.01));
      expect(roughBox.points.first.y, closeTo(0.20, 0.01));
      expect(roughBox.points.last.x, closeTo(0.20, 0.01));
      expect(roughBox.points.last.y, closeTo(0.20, 0.01));
    });

    test('둥글게 그린 닫힌 궤적을 매끄러운 원·타원으로 자동 보정한다', () {
      final roughCirclePts = <NormalizedPoint>[];
      const int n = 16;
      for (int i = 0; i <= n; i++) {
        final theta = (i / n) * 2 * math.pi;
        roughCirclePts.add(
          NormalizedPoint(
            x: 0.50 + 0.15 * math.cos(theta),
            y: 0.50 + 0.15 * math.sin(theta),
          ),
        );
      }

      final roughCircle = NormalizedStroke(
        strokeId: 's_rough_circle',
        tool: DrawingTool.pen,
        color: const Color(0xFFD81B60),
        normalizedWidth: 0.004,
        points: roughCirclePts,
      );

      final snappedLabel = roughCircle.trySnapPointsToCleanShape();
      expect(snappedLabel, equals('매끄러운 원·타원'));
      expect(roughCircle.points.length, equals(33));
    });
  });

  group('6. 필기 평행이동(translateStroke) 및 경계 클램핑 검증', () {
    test('translateStroke 호출 시 모든 포인트가 지정된 오프셋만큼 이동하고 페이지 경계(0.01~0.99)를 유지한다', () {
      final stroke = NormalizedStroke(
        strokeId: 's_move_test',
        tool: DrawingTool.pen,
        color: Colors.black,
        normalizedWidth: 0.004,
        points: [
          const NormalizedPoint(x: 0.20, y: 0.30, audioOffsetMs: 5000),
          const NormalizedPoint(x: 0.90, y: 0.05, audioOffsetMs: 5200),
        ],
      );

      stroke.translateStroke(0.15, -0.10);

      // 첫 번째 점: (0.20 + 0.15, 0.30 - 0.10) = (0.35, 0.20)
      expect(stroke.points[0].x, closeTo(0.35, 0.0001));
      expect(stroke.points[0].y, closeTo(0.20, 0.0001));
      expect(stroke.points[0].audioOffsetMs, equals(5000));

      // 두 번째 점: (0.90 + 0.15 -> 0.99로 클램핑, 0.05 - 0.10 -> 0.01로 클램핑)
      expect(stroke.points[1].x, closeTo(0.99, 0.0001));
      expect(stroke.points[1].y, closeTo(0.01, 0.0001));
    });
  });

  group('7. 듀얼 PDF 양방향 교차 핀(CrossDocumentPinLink) 및 서브노트 스크랩(SubNoteScrapClip) 검증', () {
    test('CrossDocumentPinLink와 SubNoteScrapClip이 원본 페이지 및 오디오 타임스탬프를 정확히 보존한다', () {
      const pin = CrossDocumentPinLink(
        pinId: 'pin_test_1',
        primaryPageNumber: 14,
        secondaryPageNumber: 8,
        relationSummary: '기출 p.14 ↔ 교안 p.8 (미토콘드리아 내막 모식도)',
      );

      expect(pin.primaryPageNumber, equals(14));
      expect(pin.secondaryPageNumber, equals(8));
      expect(pin.relationSummary, contains('p.14'));

      final clip = SubNoteScrapClip(
        clipId: 'clip_test_1',
        sourcePageNumber: 14,
        sourceNormalizedRect: const Rect.fromLTWH(0.1, 0.2, 0.8, 0.3),
        extractedSnippetText: '산화적 인산화 구동력 = ΔpH',
        userAnnotationMemo: '시험 직전 필수 확인',
        linkedAudioMs: 45000,
      );

      expect(clip.sourcePageNumber, equals(14));
      expect(clip.formattedAudioBadge, equals('00:45'));
    });
  });

  group('8. AI 일일 학습 할당량 계산(computeMathematicalQuotaPlan) 및 뽀모도로·캘린더(.ics) 검증', () {
    final geminiService = GeminiStudyService();
    final scheduleService = StudyScheduleNotificationAndCalendarService();

    const inputs = <SubjectExamQuotaInput>[
      SubjectExamQuotaInput(
        subjectName: '법학·행정학',
        docTitle: '핵심판례.pdf',
        dDayRemaining: 20,
        totalPages: 60,
        currentPage: 30,
        currentReadCount: 2,
        targetReadCount: 3,
        unmasteredMaskCount: 1,
        wrongAnswerCardCount: 0,
      ),
      SubjectExamQuotaInput(
        subjectName: '유기화학 I',
        docTitle: '입체화학_요약.pdf',
        dDayRemaining: 4, // 시험 임박!
        totalPages: 30,
        currentPage: 10,
        currentReadCount: 1,
        targetReadCount: 3,
        unmasteredMaskCount: 5, // 미암기 가림막 다수!
        wrongAnswerCardCount: 3,
      ),
    ];

    test('D-Day가 임박하고 미암기 가림막이 많은 과목(유기화학 I)이 1순위로 정렬되고 더 많은 학습 시간을 배정받는다', () {
      final plan = geminiService.computeMathematicalQuotaPlan(
        inputs: inputs,
        availableDailyMinutes: 150,
      );

      expect(plan.tasks.length, equals(2));
      expect(plan.tasks.first.subjectName, equals('유기화학 I'));
      expect(plan.tasks.first.dDayBadge, equals('D-4'));
      expect(
        plan.tasks.first.allocatedMinutes,
        greaterThan(plan.tasks.last.allocatedMinutes),
      );
      expect(plan.tasks.first.todayPageQuota, greaterThan(0));
      expect(plan.tasks.first.todayMaskQuota, greaterThan(0));
    });

    test('일일 할당량 플랜을 25분 뽀모도로 타임블록과 RFC 5545 표준 .ics 캘린더 문자열로 변환한다', () {
      final plan = geminiService.computeMathematicalQuotaPlan(
        inputs: inputs,
        availableDailyMinutes: 120,
      );
      final firstStart = DateTime(2026, 11, 6, 19, 0);

      final blocks = scheduleService.buildTimeBlockedPomodoroSchedule(
        plan: plan,
        firstSessionStart: firstStart,
      );

      expect(blocks, isNotEmpty);
      expect(
        blocks.first.endTime.difference(blocks.first.startTime).inMinutes,
        equals(25),
      );

      final icsContent =
          scheduleService.generateRfc5545IcsCalendarContent(blocks);
      expect(icsContent, contains('BEGIN:VCALENDAR'));
      expect(icsContent, contains('BEGIN:VEVENT'));
      expect(icsContent, contains('BEGIN:VALARM'));
      expect(icsContent, contains('TRIGGER:-PT10M'));
      expect(icsContent, contains('END:VCALENDAR'));
    });
  });

  group('9. AdaptiveStudyWorkspace 신규 5대 필기·서브노트·듀얼PDF 위젯 통합 검증', () {
    testWidgets('플로팅 툴바에서 듀얼 PDF 비교 및 플로팅 서브노트를 켜면 각 패널이 즉시 렌더링된다',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(const StudyNoteApp());
      await tester.pump(const Duration(milliseconds: 200));

      // 신규 플로팅 툴바 칩 존재 확인
      expect(find.text('필기 이동'), findsOneWidget);
      expect(find.text('도형 자동보정'), findsOneWidget);
      expect(find.textContaining('플로팅 서브노트'), findsOneWidget);
      expect(find.textContaining('듀얼 PDF 비교'), findsOneWidget);
      expect(find.text('손필기→인쇄체·표 정돈'), findsOneWidget);

      // 1) 듀얼 PDF 비교 토글 클릭 -> 우측 참조 교안 뷰어 표시 확인
      await tester.tap(find.textContaining('듀얼 PDF 비교'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('참조 교안:'), findsOneWidget);

      // 2) 플로팅 서브노트 토글 클릭 -> 단권화 서브노트 팝업 표시 확인
      await tester.tap(find.textContaining('플로팅 서브노트'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('단권화 서브노트'), findsOneWidget);
    });
  });
}

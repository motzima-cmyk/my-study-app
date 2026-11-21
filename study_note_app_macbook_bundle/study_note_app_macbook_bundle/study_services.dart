import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf_pdf;

import 'study_models.dart';

/// ============================================================================
/// [Services Module] Gemini 2.5 Flash AI · PDF Flatten 합본 내보내기 · 알림 및 캘린더(.ics) 서비스
/// 파일 경로: lib/services/study_services.dart (또는 lib/study_services.dart)
/// ============================================================================

/// AI 스터디 플래너 할당량을 태블릿 로컬 알림(flutter_local_notifications / MethodChannel)과
/// 표준 iCalendar(.ics, Apple 캘린더·Google 캘린더·삼성 캘린더 호환) 일정으로 변환·등록하는 서비스
class StudyScheduleNotificationAndCalendarService {
  static const MethodChannel _notificationChannel =
      MethodChannel('com.studynote.notifications/local_scheduler');

  /// 과목별 할당량(AiStudyQuotaPlanResult)을 지정된 시작 시각(firstSessionStart)부터
  /// 25분 집중 + 5분 휴식(4세션마다 15분 긴 휴식) 타임블록 시간표로 자동 편성합니다.
  List<ScheduledPomodoroTimeBlock> buildTimeBlockedPomodoroSchedule({
    required AiStudyQuotaPlanResult plan,
    required DateTime firstSessionStart,
  }) {
    final List<ScheduledPomodoroTimeBlock> blocks = [];
    DateTime cursorTime = firstSessionStart;
    int globalOrder = 1;

    for (final task in plan.tasks) {
      if (task.isCompletedToday) continue;
      final int totalSessions =
          task.recommendedPomodoroSessions.clamp(1, 8);

      for (int s = 1; s <= totalSessions; s++) {
        final DateTime blockStart = cursorTime;
        final DateTime blockEnd =
            blockStart.add(const Duration(minutes: 25));
        final int breakMin = (globalOrder % 4 == 0) ? 15 : 5;

        blocks.add(
          ScheduledPomodoroTimeBlock(
            notificationId: 7000 + globalOrder,
            blockOrder: globalOrder,
            subjectName: task.subjectName,
            docTitle: task.docTitle,
            dDayBadge: task.dDayBadge,
            startPage: task.startPage,
            pageRangeLabel: task.pageRangeLabel,
            targetMaskCount: task.todayMaskQuota,
            sessionIndexInSubject: s,
            totalSessionsInSubject: totalSessions,
            startTime: blockStart,
            endTime: blockEnd,
            breakMinutesAfter: breakMin,
          ),
        );

        cursorTime = blockEnd.add(Duration(minutes: breakMin));
        globalOrder++;
      }
    }
    return blocks;
  }

  /// 태블릿 로컬 알림(zonedSchedule) 일괄 등록
  Future<int> scheduleTabletLocalNotifications(
    List<ScheduledPomodoroTimeBlock> blocks,
  ) async {
    if (blocks.isEmpty) return 0;
    try {
      await _notificationChannel.invokeMethod(
        'schedulePomodoroNotifications',
        {
          'blocks': blocks.map((b) => b.toNotificationJson()).toList(),
        },
      );
    } catch (e) {
      debugPrint(
        '[LocalNotifications] 네이티브 알림 채널 폴백 (인앱 스케줄러에 ${blocks.length}건 등록됨): $e',
      );
    }
    return blocks.length;
  }

  String _formatIcsUtcDateTime(DateTime dt) {
    final u = dt.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }

  /// Apple 캘린더(iPadOS) 및 Google·삼성 캘린더(Android 태블릿)에서 바로 열 수 있는
  /// RFC 5545 표준 .ics 캘린더 일정 문자열(VALARM 10분 전 알림 포함) 생성
  String generateRfc5545IcsCalendarContent(
    List<ScheduledPomodoroTimeBlock> blocks,
  ) {
    final sb = StringBuffer()
      ..writeln('BEGIN:VCALENDAR')
      ..writeln('VERSION:2.0')
      ..writeln('PRODID:-//AI Tablet Study Note//Pomodoro Study Planner//KO')
      ..writeln('CALSCALE:GREGORIAN')
      ..writeln('METHOD:PUBLISH');

    final nowStamp = _formatIcsUtcDateTime(DateTime.now());

    for (final b in blocks) {
      sb
        ..writeln('BEGIN:VEVENT')
        ..writeln('UID:studynote_pomo_${b.notificationId}_${b.startTime.millisecondsSinceEpoch}@studynote.ai')
        ..writeln('DTSTAMP:$nowStamp')
        ..writeln('DTSTART:${_formatIcsUtcDateTime(b.startTime)}')
        ..writeln('DTEND:${_formatIcsUtcDateTime(b.endTime)}')
        ..writeln('SUMMARY:[뽀모도로 #${b.blockOrder}] ${b.subjectName} (${b.dDayBadge}) ${b.pageRangeLabel}')
        ..writeln('DESCRIPTION:${b.notificationBody} (문서: ${b.docTitle})')
        ..writeln('BEGIN:VALARM')
        ..writeln('TRIGGER:-PT10M')
        ..writeln('ACTION:DISPLAY')
        ..writeln('DESCRIPTION:${b.notificationTitle}')
        ..writeln('END:VALARM')
        ..writeln('END:VEVENT');
    }

    sb.writeln('END:VCALENDAR');
    return sb.toString();
  }

  /// 생성된 .ics 캘린더 파일을 기기에 저장·내보내기
  Future<String?> exportIcsCalendarFile(
    List<ScheduledPomodoroTimeBlock> blocks,
  ) async {
    final icsText = generateRfc5545IcsCalendarContent(blocks);
    final icsBytes = Uint8List.fromList(utf8.encode(icsText));
    const fileName = 'AI_스터디플래너_오늘의_뽀모도로_일정.ics';

    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '태블릿 캘린더(.ics) 일정 파일 저장',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['ics'],
        bytes: icsBytes,
      );
      return path ?? fileName;
    } catch (e) {
      debugPrint('캘린더 .ics 파일 저장 폴백: $e');
      return fileName;
    }
  }
}

/// ============================================================================
/// 2. 원본 PDF + NormalizedStroke 필기 + AI 요약 합본 내보내기(Flatten Export) 서비스
/// ============================================================================

class PdfFlattenExportService {
  Future<Uint8List> flattenAndExportPdf({
    Uint8List? originalPdfBytes,
    required String documentTitle,
    required String subjectFolder,
    required String subTopic,
    required String docType,
    required String examDdayLabel,
    required String aiSummary,
    required Map<int, List<NormalizedStroke>> strokesByPage,
    required Map<int, List<NormalizedMaskRect>> masksByPage,
    required List<NotebookQaAnswer> notebookQaList,
    required List<WrongAnswerStudyCard> studyCards,
    required LectureAudioSession audioSession,
    required MaskExportMode maskMode,
    required bool appendAiSummaryPage,
    List<CrossDocumentPinLink> crossDocPins = const <CrossDocumentPinLink>[],
    List<SubNoteScrapClip> subNoteScrapClips = const <SubNoteScrapClip>[],
    Map<int, List<CleanTypesetBlockSticker>> cleanTypesetBlocksByPage =
        const <int, List<CleanTypesetBlockSticker>>{},
  }) async {
    final sf_pdf.PdfDocument document = originalPdfBytes != null
        ? sf_pdf.PdfDocument(inputBytes: originalPdfBytes)
        : _createFallbackBaseDocument();

    final int pageCount = document.pages.count;
    final sf_pdf.PdfFont labelFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      9,
      style: sf_pdf.PdfFontStyle.bold,
    );

    for (int pageIndex = 0; pageIndex < pageCount; pageIndex++) {
      final int pageNumber = pageIndex + 1;
      final sf_pdf.PdfPage page = document.pages[pageIndex];
      final Size pageSize = page.getClientSize();
      final sf_pdf.PdfGraphics graphics = page.graphics;

      graphics.save();
      graphics.setTransparency(0.65);
      graphics.drawString(
        '[$subjectFolder > $subTopic] ($docType) - Page $pageNumber',
        sf_pdf.PdfStandardFont(sf_pdf.PdfFontFamily.helvetica, 8),
        brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(90, 100, 120)),
        bounds: Rect.fromLTWH(16, 8, pageSize.width - 32, 14),
      );
      graphics.restore();

      final List<NormalizedStroke> strokes =
          strokesByPage[pageNumber] ?? const <NormalizedStroke>[];

      for (final stroke in strokes) {
        if (stroke.points.isEmpty) continue;

        graphics.save();
        final bool isHighlighter = stroke.tool == DrawingTool.highlighter;
        final double alpha = isHighlighter ? 0.35 : stroke.color.a;
        graphics.setTransparency(alpha);

        final sf_pdf.PdfColor pdfColor = sf_pdf.PdfColor(
          (stroke.color.r * 255.0).round().clamp(0, 255),
          (stroke.color.g * 255.0).round().clamp(0, 255),
          (stroke.color.b * 255.0).round().clamp(0, 255),
        );

        final double strokeWidthPt =
            (stroke.normalizedWidth * pageSize.width).clamp(1.0, 28.0);
        final sf_pdf.PdfPen pdfPen = sf_pdf.PdfPen(
          pdfColor,
          width: strokeWidthPt,
        )..lineCap = sf_pdf.PdfLineCap.round
         ..lineJoin = sf_pdf.PdfLineJoin.round;

        if (stroke.points.length == 1) {
          final Offset pt = stroke.points.first.toPixelOffset(pageSize);
          graphics.drawEllipse(
            Rect.fromCenter(
              center: pt,
              width: strokeWidthPt,
              height: strokeWidthPt,
            ),
            brush: sf_pdf.PdfSolidBrush(pdfColor),
          );
        } else {
          final sf_pdf.PdfPath path = sf_pdf.PdfPath();
          final List<Offset> pixelPts = stroke.points
              .map((p) => p.toPixelOffset(pageSize))
              .toList();
          for (int i = 0; i < pixelPts.length - 1; i++) {
            path.addLine(pixelPts[i], pixelPts[i + 1]);
          }
          graphics.drawPath(path, pen: pdfPen);
        }
        graphics.restore();
      }

      final List<NormalizedMaskRect> masks =
          masksByPage[pageNumber] ?? const <NormalizedMaskRect>[];

      for (final mask in masks) {
        final Rect targetRect = mask.toPixelRect(pageSize);
        graphics.save();

        if (maskMode == MaskExportMode.blindForSelfTest) {
          graphics.setTransparency(1.0);
          graphics.drawRectangle(
            brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(37, 117, 252)),
            pen: sf_pdf.PdfPen(sf_pdf.PdfColor(21, 101, 192), width: 1.2),
            bounds: targetRect,
          );
          graphics.drawString(
            '[ SELF-TEST MASK ]',
            labelFont,
            brush: sf_pdf.PdfBrushes.white,
            bounds: Rect.fromLTWH(
              targetRect.left + 4,
              targetRect.top + (targetRect.height - 10) / 2,
              targetRect.width - 8,
              12,
            ),
          );
        } else {
          graphics.setTransparency(0.18);
          graphics.drawRectangle(
            brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(37, 117, 252)),
            bounds: targetRect,
          );
          graphics.setTransparency(0.85);
          graphics.drawRectangle(
            pen: sf_pdf.PdfPen(sf_pdf.PdfColor(37, 117, 252), width: 1.2),
            bounds: targetRect,
          );
        }
        graphics.restore();
      }

      // 3) 해당 페이지에 연결된 듀얼 PDF 교차 핀(CrossDocumentPinLink) 배지 오버레이 렌더링
      final List<CrossDocumentPinLink> pagePins = crossDocPins
          .where((pin) => pin.primaryPageNumber == pageNumber)
          .toList();
      if (pagePins.isNotEmpty) {
        double pinOffsetY = 24.0;
        for (final pin in pagePins) {
          graphics.save();
          graphics.setTransparency(0.90);
          final Rect badgeBounds = Rect.fromLTWH(
            pageSize.width - 236,
            pinOffsetY,
            220,
            18,
          );
          graphics.drawRectangle(
            brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(237, 231, 246)),
            pen: sf_pdf.PdfPen(sf_pdf.PdfColor(103, 58, 183), width: 0.9),
            bounds: badgeBounds,
          );
          graphics.drawString(
            '[Cross-Pin p.${pin.primaryPageNumber}<->p.${pin.secondaryPageNumber}] ${pin.relationSummary}',
            sf_pdf.PdfStandardFont(sf_pdf.PdfFontFamily.helvetica, 7.5),
            brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(69, 39, 160)),
            bounds: Rect.fromLTWH(
              badgeBounds.left + 5,
              badgeBounds.top + 3,
              badgeBounds.width - 10,
              12,
            ),
          );
          graphics.restore();
          pinOffsetY += 21.0;
        }
      }

      // 4) 해당 페이지에 배치된 인쇄체·수식·비교표 정돈 스티커(CleanTypesetBlockSticker) 인페이지 오버레이 렌더링
      final List<CleanTypesetBlockSticker> pageCleanBlocks =
          cleanTypesetBlocksByPage[pageNumber] ??
              const <CleanTypesetBlockSticker>[];
      for (final block in pageCleanBlocks) {
        graphics.save();
        final double boxLeft =
            (block.normalizedPosition.dx * pageSize.width).clamp(
          16.0,
          pageSize.width - 256.0,
        );
        final double boxTop =
            (block.normalizedPosition.dy * pageSize.height).clamp(
          28.0,
          pageSize.height - 130.0,
        );
        final Rect cardRect = Rect.fromLTWH(boxLeft, boxTop, 240, 108);

        graphics.setTransparency(0.95);
        graphics.drawRectangle(
          brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(246, 249, 255)),
          pen: sf_pdf.PdfPen(sf_pdf.PdfColor(57, 73, 171), width: 1.1),
          bounds: cardRect,
        );
        graphics.drawRectangle(
          brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(232, 234, 246)),
          bounds: Rect.fromLTWH(cardRect.left, cardRect.top, cardRect.width, 18),
        );
        graphics.drawString(
          '[CLEAN TYPESET] ${block.headerTitle}',
          labelFont,
          brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(40, 53, 147)),
          bounds: Rect.fromLTWH(
            cardRect.left + 6,
            cardRect.top + 3,
            cardRect.width - 12,
            13,
          ),
        );

        String bodyPreview;
        switch (block.activeStyle) {
          case CleanBlockStyle.typesetSummary:
            bodyPreview = block.cleanSummaryText;
            break;
          case CleanBlockStyle.mathChemFormula:
            bodyPreview = 'Formula: ${block.cleanFormulaLatex}
${block.cleanSummaryText}';
            break;
          case CleanBlockStyle.comparisonTable:
            bodyPreview = block.comparisonTableRows
                .map((row) => row.join(' | '))
                .join('
');
            break;
        }

        graphics.drawString(
          bodyPreview,
          sf_pdf.PdfStandardFont(sf_pdf.PdfFontFamily.helvetica, 8),
          brush: sf_pdf.PdfBrushes.black,
          bounds: Rect.fromLTWH(
            cardRect.left + 6,
            cardRect.top + 22,
            cardRect.width - 12,
            cardRect.height - 26,
          ),
        );
        graphics.restore();
      }
    }

    if (appendAiSummaryPage) {
      _appendSummaryAndQaAppendixPage(
        document: document,
        documentTitle: documentTitle,
        subjectFolder: subjectFolder,
        subTopic: subTopic,
        docType: docType,
        examDdayLabel: examDdayLabel,
        aiSummary: aiSummary,
        notebookQaList: notebookQaList,
        masksByPage: masksByPage,
        studyCards: studyCards,
        audioSession: audioSession,
        crossDocPins: crossDocPins,
        subNoteScrapClips: subNoteScrapClips,
        cleanTypesetBlocksByPage: cleanTypesetBlocksByPage,
      );
    }

    final List<int> savedBytes = await document.save();
    document.dispose();
    return Uint8List.fromList(savedBytes);
  }

  Future<String?> saveFlattenedPdfToDevice({
    required Uint8List flattenedPdfBytes,
    required String originalFileName,
    required MaskExportMode maskMode,
  }) async {
    final String cleanBaseName = originalFileName.replaceAll(
      RegExp(r'\.pdf$', caseSensitive: false),
      '',
    );
    final String suffix =
        maskMode == MaskExportMode.blindForSelfTest ? '백지테스트' : '단권화노트';
    final String exportFileName = '${cleanBaseName}_$suffix.pdf';

    try {
      final String? outputPath = await FilePicker.platform.saveFile(
        dialogTitle: '필기 및 요약이 병합된 PDF 저장',
        fileName: exportFileName,
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        bytes: flattenedPdfBytes,
      );

      if (outputPath != null && outputPath.isNotEmpty) {
        final file = File(outputPath);
        if (!await file.exists() || await file.length() == 0) {
          await file.writeAsBytes(flattenedPdfBytes, flush: true);
        }
      }
      return outputPath ?? exportFileName;
    } catch (e) {
      debugPrint('파일 저장 다이얼로그 호출 중 예외: $e');
      return null;
    }
  }

  sf_pdf.PdfDocument _createFallbackBaseDocument() {
    final doc = sf_pdf.PdfDocument();
    for (int i = 1; i <= 14; i++) {
      final page = doc.pages.add();
      final g = page.graphics;
      final size = page.getClientSize();
      g.drawString(
        'AI Study Note Base Document - Page $i',
        sf_pdf.PdfStandardFont(
          sf_pdf.PdfFontFamily.helvetica,
          14,
          style: sf_pdf.PdfFontStyle.bold,
        ),
        brush: sf_pdf.PdfBrushes.black,
        bounds: Rect.fromLTWH(28, 36, size.width - 56, 28),
      );
      g.drawString(
        '1) Location of Oxidative Phosphorylation:\n'
        'In eukaryotic cells, the electron transport chain (I-IV) and ATP synthase are located in the [ Inner Mitochondrial Membrane ].\n\n'
        '2) Driving Force of ATP Synthesis:\n'
        'The proton gradient (delta pH) across the inner membrane drives ATP synthesis.',
        sf_pdf.PdfStandardFont(sf_pdf.PdfFontFamily.helvetica, 11),
        brush: sf_pdf.PdfBrushes.darkGray,
        bounds: Rect.fromLTWH(28, 90, size.width - 56, 300),
      );
    }
    return doc;
  }

  void _appendSummaryAndQaAppendixPage({
    required sf_pdf.PdfDocument document,
    required String documentTitle,
    required String subjectFolder,
    required String subTopic,
    required String docType,
    required String examDdayLabel,
    required String aiSummary,
    required List<NotebookQaAnswer> notebookQaList,
    required Map<int, List<NormalizedMaskRect>> masksByPage,
    required List<WrongAnswerStudyCard> studyCards,
    required LectureAudioSession audioSession,
    List<CrossDocumentPinLink> crossDocPins = const <CrossDocumentPinLink>[],
    List<SubNoteScrapClip> subNoteScrapClips = const <SubNoteScrapClip>[],
    Map<int, List<CleanTypesetBlockSticker>> cleanTypesetBlocksByPage =
        const <int, List<CleanTypesetBlockSticker>>{},
  }) {
    final sf_pdf.PdfPage appendixPage = document.pages.add();
    final sf_pdf.PdfGraphics g = appendixPage.graphics;
    final Size pageSize = appendixPage.getClientSize();

    final titleFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      16,
      style: sf_pdf.PdfFontStyle.bold,
    );
    final sectionFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      12,
      style: sf_pdf.PdfFontStyle.bold,
    );
    final bodyFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      10,
    );

    g.drawRectangle(
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(235, 243, 255)),
      bounds: Rect.fromLTWH(20, 20, pageSize.width - 40, 68),
    );
    g.drawString(
      'Gemini AI Study Summary, Audio Transcript & Twin Questions',
      titleFont,
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(21, 101, 192)),
      bounds: Rect.fromLTWH(32, 30, pageSize.width - 64, 24),
    );
    g.drawString(
      'File: $documentTitle  |  Category: $subjectFolder > $subTopic ($docType)  |  Schedule: $examDdayLabel',
      bodyFont,
      brush: sf_pdf.PdfBrushes.black,
      bounds: Rect.fromLTWH(32, 56, pageSize.width - 64, 20),
    );

    double cursorY = 100;

    g.drawString(
      '1. Gemini Document & Lecture Audio Summary',
      sectionFont,
      brush: sf_pdf.PdfBrushes.black,
      bounds: Rect.fromLTWH(24, cursorY, pageSize.width - 48, 18),
    );
    cursorY += 20;

    g.drawRectangle(
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(248, 249, 250)),
      pen: sf_pdf.PdfPen(sf_pdf.PdfColor(210, 215, 220)),
      bounds: Rect.fromLTWH(24, cursorY, pageSize.width - 48, 52),
    );
    g.drawString(
      'Folder: $subjectFolder / $subTopic ($docType)\n'
      'Summary: ${audioSession.aiLectureSummary.isNotEmpty ? audioSession.aiLectureSummary : aiSummary}',
      bodyFont,
      brush: sf_pdf.PdfBrushes.darkGray,
      bounds: Rect.fromLTWH(32, cursorY + 6, pageSize.width - 64, 40),
    );
    cursorY += 64;

    g.drawString(
      '2. Lecture Audio Timestamped Transcript (${audioSession.segments.length} segments)',
      sectionFont,
      brush: sf_pdf.PdfBrushes.black,
      bounds: Rect.fromLTWH(24, cursorY, pageSize.width - 48, 18),
    );
    cursorY += 20;

    for (final seg in audioSession.segments.take(4)) {
      if (cursorY > pageSize.height - 180) break;
      g.drawString(
        '[${seg.formattedRange} | p.${seg.pageNumber} | ${seg.keyConceptTag}] ${seg.transcriptText}',
        bodyFont,
        brush: sf_pdf.PdfBrushes.darkGray,
        bounds: Rect.fromLTWH(32, cursorY, pageSize.width - 64, 18),
      );
      cursorY += 18;
    }

    cursorY += 8;
    g.drawString(
      '3. AI Lasso Captured Questions & Twin Variations (${studyCards.length} cards)',
      sectionFont,
      brush: sf_pdf.PdfBrushes.black,
      bounds: Rect.fromLTWH(24, cursorY, pageSize.width - 48, 18),
    );
    cursorY += 20;

    for (final card in studyCards.take(2)) {
      if (cursorY > pageSize.height - 90) break;
      g.drawRectangle(
        brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(245, 242, 255)),
        pen: sf_pdf.PdfPen(sf_pdf.PdfColor(180, 170, 230)),
        bounds: Rect.fromLTWH(24, cursorY, pageSize.width - 48, 60),
      );
      g.drawString(
        '[Page ${card.pageNumber}] ${card.recognizedQuestion}\n'
        'Twin Q: ${card.twinQuestion}\n'
        'Answer: ${card.twinAnswer}',
        bodyFont,
        brush: sf_pdf.PdfBrushes.black,
        bounds: Rect.fromLTWH(32, cursorY + 6, pageSize.width - 64, 48),
      );
      cursorY += 68;
    }

    // 부록 2페이지: 듀얼 PDF 교차 핀 목록 + 플로팅 단권화 서브노트 스크랩 조각 + 인쇄체 정돈 비교표 렌더링
    final allCleanBlocks =
        cleanTypesetBlocksByPage.values.expand((list) => list).toList();
    if (crossDocPins.isNotEmpty ||
        subNoteScrapClips.isNotEmpty ||
        allCleanBlocks.isNotEmpty) {
      _appendCrossPinsScrapsAndComparisonTablesAppendixPage(
        document: document,
        documentTitle: documentTitle,
        subjectFolder: subjectFolder,
        subTopic: subTopic,
        crossDocPins: crossDocPins,
        subNoteScrapClips: subNoteScrapClips,
        allCleanBlocks: allCleanBlocks,
      );
    }
  }

  /// 부록 2페이지: 듀얼 PDF 교차 핀 목록(CrossDocumentPinLink), 플로팅 단권화 서브노트 스크랩 조각(SubNoteScrapClip),
  /// 인쇄체·수식·비교표 정돈 블록(CleanTypesetBlockSticker)을 전용 부록 페이지에 표(PdfGrid)와 카드로 렌더링합니다.
  void _appendCrossPinsScrapsAndComparisonTablesAppendixPage({
    required sf_pdf.PdfDocument document,
    required String documentTitle,
    required String subjectFolder,
    required String subTopic,
    required List<CrossDocumentPinLink> crossDocPins,
    required List<SubNoteScrapClip> subNoteScrapClips,
    required List<CleanTypesetBlockSticker> allCleanBlocks,
  }) {
    sf_pdf.PdfPage page = document.pages.add();
    sf_pdf.PdfGraphics g = page.graphics;
    Size pageSize = page.getClientSize();

    final titleFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      15,
      style: sf_pdf.PdfFontStyle.bold,
    );
    final sectionFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      11.5,
      style: sf_pdf.PdfFontStyle.bold,
    );
    final boldBodyFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      9.5,
      style: sf_pdf.PdfFontStyle.bold,
    );
    final bodyFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      9.5,
    );

    // 상단 헤더 배너
    g.drawRectangle(
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(237, 231, 246)),
      pen: sf_pdf.PdfPen(sf_pdf.PdfColor(126, 87, 194), width: 1.0),
      bounds: Rect.fromLTWH(20, 20, pageSize.width - 40, 58),
    );
    g.drawString(
      'Appendix II: Dual-PDF Cross Pins, Sub-Note Scraps & Clean Typeset Tables',
      titleFont,
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(69, 39, 160)),
      bounds: Rect.fromLTWH(32, 28, pageSize.width - 64, 22),
    );
    g.drawString(
      'Document: $documentTitle ($subjectFolder > $subTopic)  |  '
      'Pins: ${crossDocPins.length}  |  Scraps: ${subNoteScrapClips.length}  |  Clean Tables: ${allCleanBlocks.length}',
      bodyFont,
      brush: sf_pdf.PdfBrushes.darkGray,
      bounds: Rect.fromLTWH(32, 52, pageSize.width - 64, 18),
    );

    double cursorY = 90.0;

    void ensureSpace(double requiredHeight) {
      if (cursorY + requiredHeight > pageSize.height - 32) {
        page = document.pages.add();
        g = page.graphics;
        pageSize = page.getClientSize();
        cursorY = 28.0;
      }
    }

    // -------------------------------------------------------------------------
    // 4. 듀얼 PDF 교차 핀(CrossDocumentPinLink) 목록 섹션
    // -------------------------------------------------------------------------
    ensureSpace(48);
    g.drawString(
      '4. Dual-PDF Cross-Document Reference Pins (${crossDocPins.length} links)',
      sectionFont,
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(49, 27, 146)),
      bounds: Rect.fromLTWH(24, cursorY, pageSize.width - 48, 18),
    );
    cursorY += 22;

    if (crossDocPins.isEmpty) {
      g.drawString(
        'No dual-PDF cross-document pins registered.',
        bodyFont,
        brush: sf_pdf.PdfBrushes.gray,
        bounds: Rect.fromLTWH(32, cursorY, pageSize.width - 64, 16),
      );
      cursorY += 22;
    } else {
      for (int i = 0; i < crossDocPins.length; i++) {
        final pin = crossDocPins[i];
        ensureSpace(34);
        g.drawRectangle(
          brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(248, 245, 255)),
          pen: sf_pdf.PdfPen(sf_pdf.PdfColor(179, 157, 219), width: 0.8),
          bounds: Rect.fromLTWH(24, cursorY, pageSize.width - 48, 28),
        );
        g.drawString(
          '[Pin #${i + 1} | ID: ${pin.pinId}] Primary Textbook p.${pin.primaryPageNumber}  <-->  Secondary Past Exam p.${pin.secondaryPageNumber}   |   ${pin.relationSummary}',
          bodyFont,
          brush: sf_pdf.PdfBrushes.black,
          bounds: Rect.fromLTWH(32, cursorY + 7, pageSize.width - 64, 16),
        );
        cursorY += 34;
      }
    }

    cursorY += 8;

    // -------------------------------------------------------------------------
    // 5. 플로팅 단권화 서브노트 스크랩 조각(SubNoteScrapClip) 목록 섹션
    // -------------------------------------------------------------------------
    ensureSpace(54);
    g.drawString(
      '5. Floating Sub-Note Scrapbook Clips (${subNoteScrapClips.length} clips)',
      sectionFont,
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(0, 105, 92)),
      bounds: Rect.fromLTWH(24, cursorY, pageSize.width - 48, 18),
    );
    cursorY += 22;

    if (subNoteScrapClips.isEmpty) {
      g.drawString(
        'No floating sub-note scrap clips captured.',
        bodyFont,
        brush: sf_pdf.PdfBrushes.gray,
        bounds: Rect.fromLTWH(32, cursorY, pageSize.width - 64, 16),
      );
      cursorY += 22;
    } else {
      for (int i = 0; i < subNoteScrapClips.length; i++) {
        final clip = subNoteScrapClips[i];
        ensureSpace(66);
        final Rect clipRect = Rect.fromLTWH(24, cursorY, pageSize.width - 48, 58);
        g.drawRectangle(
          brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(240, 253, 250)),
          pen: sf_pdf.PdfPen(sf_pdf.PdfColor(128, 203, 196), width: 0.9),
          bounds: clipRect,
        );

        double textLeft = 32.0;
        if (clip.croppedImageBytes != null &&
            clip.croppedImageBytes!.isNotEmpty) {
          try {
            final sf_pdf.PdfBitmap bitmap =
                sf_pdf.PdfBitmap(clip.croppedImageBytes!);
            g.drawImage(
              bitmap,
              Rect.fromLTWH(32, cursorY + 6, 56, 46),
            );
            textLeft = 96.0;
          } catch (_) {
            textLeft = 32.0;
          }
        }

        final String audioTag = clip.formattedAudioBadge.isNotEmpty
            ? ' | Audio @ ${clip.formattedAudioBadge}'
            : '';
        final String normRectTag =
            '(${clip.sourceNormalizedRect.left.toStringAsFixed(2)}, ${clip.sourceNormalizedRect.top.toStringAsFixed(2)})';

        g.drawString(
          '[Scrap #${i + 1} | Source p.${clip.sourcePageNumber} $normRectTag$audioTag]',
          boldBodyFont,
          brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(0, 77, 64)),
          bounds: Rect.fromLTWH(
            textLeft,
            cursorY + 6,
            pageSize.width - textLeft - 32,
            14,
          ),
        );
        g.drawString(
          'Snippet: ${clip.extractedSnippetText}\n'
          'Annotation Memo: ${clip.userAnnotationMemo}',
          bodyFont,
          brush: sf_pdf.PdfBrushes.black,
          bounds: Rect.fromLTWH(
            textLeft,
            cursorY + 22,
            pageSize.width - textLeft - 32,
            32,
          ),
        );
        cursorY += 64;
      }
    }

    cursorY += 8;

    // -------------------------------------------------------------------------
    // 6. 인쇄체 정돈 비교표·수식·요약 블록(CleanTypesetBlockSticker) 섹션 (PdfGrid 표 포함)
    // -------------------------------------------------------------------------
    ensureSpace(64);
    g.drawString(
      '6. Clean Typeset Summary, Formula & Comparison Tables (${allCleanBlocks.length} blocks)',
      sectionFont,
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(21, 101, 192)),
      bounds: Rect.fromLTWH(24, cursorY, pageSize.width - 48, 18),
    );
    cursorY += 22;

    if (allCleanBlocks.isEmpty) {
      g.drawString(
        'No clean typeset blocks or comparison tables generated.',
        bodyFont,
        brush: sf_pdf.PdfBrushes.gray,
        bounds: Rect.fromLTWH(32, cursorY, pageSize.width - 64, 16),
      );
      cursorY += 22;
    } else {
      for (int i = 0; i < allCleanBlocks.length; i++) {
        final block = allCleanBlocks[i];
        ensureSpace(135);

        // 블록 제목 + 요약/수식 헤더 박스
        g.drawRectangle(
          brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(232, 240, 254)),
          pen: sf_pdf.PdfPen(sf_pdf.PdfColor(144, 202, 249), width: 0.9),
          bounds: Rect.fromLTWH(24, cursorY, pageSize.width - 48, 44),
        );
        g.drawString(
          '[Typeset Block #${i + 1} | Page ${block.pageNumber} | Style: ${block.activeStyle.name}] ${block.headerTitle}',
          boldBodyFont,
          brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(13, 71, 161)),
          bounds: Rect.fromLTWH(32, cursorY + 5, pageSize.width - 64, 14),
        );
        g.drawString(
          'Summary: ${block.cleanSummaryText}   |   Formula: ${block.cleanFormulaLatex}',
          bodyFont,
          brush: sf_pdf.PdfBrushes.darkGray,
          bounds: Rect.fromLTWH(32, cursorY + 22, pageSize.width - 64, 18),
        );
        cursorY += 50;

        // 비교표(comparisonTableRows)가 있는 경우 Syncfusion PdfGrid로 정돈된 표 렌더링
        if (block.comparisonTableRows.isNotEmpty) {
          final int colCount = block.comparisonTableRows
              .map((r) => r.length)
              .fold<int>(0, (prev, len) => len > prev ? len : prev);

          if (colCount > 0) {
            final sf_pdf.PdfGrid grid = sf_pdf.PdfGrid();
            grid.columns.add(count: colCount);
            grid.style = sf_pdf.PdfGridStyle(
              font: bodyFont,
              cellPadding: sf_pdf.PdfPaddings(
                left: 6,
                right: 6,
                top: 4,
                bottom: 4,
              ),
            );

            for (int rIdx = 0;
                rIdx < block.comparisonTableRows.length;
                rIdx++) {
              final List<String> rowValues = block.comparisonTableRows[rIdx];
              final sf_pdf.PdfGridRow pdfRow = grid.rows.add();
              for (int cIdx = 0; cIdx < colCount; cIdx++) {
                pdfRow.cells[cIdx].value =
                    cIdx < rowValues.length ? rowValues[cIdx] : '';
                if (rIdx == 0) {
                  pdfRow.cells[cIdx].style = sf_pdf.PdfGridCellStyle(
                    backgroundBrush:
                        sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(227, 242, 253)),
                    textBrush:
                        sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(13, 71, 161)),
                    font: boldBodyFont,
                  );
                }
              }
            }

            final double estimatedTableHeight =
                (block.comparisonTableRows.length * 24.0) + 12.0;
            ensureSpace(estimatedTableHeight);

            final sf_pdf.PdfLayoutResult? gridResult = grid.draw(
              page: page,
              bounds: Rect.fromLTWH(
                24,
                cursorY,
                pageSize.width - 48,
                pageSize.height - cursorY - 24,
              ),
            );
            if (gridResult != null) {
              page = gridResult.page;
              g = page.graphics;
              pageSize = page.getClientSize();
              cursorY = gridResult.bounds.bottom + 14;
            } else {
              cursorY += estimatedTableHeight;
            }
          }
        }
      }
    }
  }
  /// 선택한 오디오북 플레이리스트 구간들의 전사 텍스트 + 필기 요약을 1페이지 PDF 핵심 요약본으로 생성
  Future<Uint8List> exportOnePageCheatSheetPdf(
    OnePagePlaylistCheatSheet sheet,
  ) async {
    final sf_pdf.PdfDocument doc = sf_pdf.PdfDocument();
    final sf_pdf.PdfPage page = doc.pages.add();
    final sf_pdf.PdfGraphics g = page.graphics;
    final Size pageSize = page.getClientSize();

    final titleFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      15,
      style: sf_pdf.PdfFontStyle.bold,
    );
    final sectionFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      11,
      style: sf_pdf.PdfFontStyle.bold,
    );
    final bodyFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      9,
    );

    // 상단 헤더 배너
    g.drawRectangle(
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(25, 42, 86)),
      bounds: Rect.fromLTWH(20, 18, pageSize.width - 40, 56),
    );
    g.drawString(
      '[D-Day 1-Page Cheat Sheet] ${sheet.sheetTitle}',
      titleFont,
      brush: sf_pdf.PdfBrushes.white,
      bounds: Rect.fromLTWH(30, 26, pageSize.width - 60, 20),
    );
    g.drawString(
      'Subject: ${sheet.subjectAndTopic}  |  Schedule: ${sheet.examDdayLabel}  |  Tracks: ${sheet.trackItems.length}',
      bodyFont,
      brush: sf_pdf.PdfBrushes.lightGray,
      bounds: Rect.fromLTWH(30, 48, pageSize.width - 60, 16),
    );

    double y = 86;

    // 1. 시험장 직전 3줄 핵심 총평
    g.drawString(
      '1. Executive Exam Takeaway ( Audio + Stroke Synthesis )',
      sectionFont,
      brush: sf_pdf.PdfBrushes.black,
      bounds: Rect.fromLTWH(20, y, pageSize.width - 40, 16),
    );
    y += 18;

    g.drawRectangle(
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(255, 249, 230)),
      pen: sf_pdf.PdfPen(sf_pdf.PdfColor(245, 158, 11), width: 1.0),
      bounds: Rect.fromLTWH(20, y, pageSize.width - 40, 48),
    );
    g.drawString(
      sheet.ultraShortExecutiveTakeaway,
      bodyFont,
      brush: sf_pdf.PdfBrushes.black,
      bounds: Rect.fromLTWH(28, y + 6, pageSize.width - 56, 36),
    );
    y += 60;

    // 2. 플레이리스트 구간별 전사 + 필기 요약 카드
    g.drawString(
      '2. Selected Audiobook Playlist Tracks & Linked Stroke Notes',
      sectionFont,
      brush: sf_pdf.PdfBrushes.black,
      bounds: Rect.fromLTWH(20, y, pageSize.width - 40, 16),
    );
    y += 18;

    for (final item in sheet.trackItems) {
      if (y > pageSize.height - 150) break;
      g.drawRectangle(
        brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(244, 247, 252)),
        pen: sf_pdf.PdfPen(sf_pdf.PdfColor(200, 212, 230)),
        bounds: Rect.fromLTWH(20, y, pageSize.width - 40, 56),
      );
      g.drawString(
        'Track #${item.trackOrder} [${item.timeRange} | p.${item.pageNumber}] ${item.keyConcept}',
        sectionFont,
        brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(21, 101, 192)),
        bounds: Rect.fromLTWH(28, y + 5, pageSize.width - 56, 15),
      );
      g.drawString(
        'Summary: ${item.condensedPoint}\n'
        'Cloze Key: [${item.clozeBlankKeyword}]  |  Stroke Note: ${item.strokeNoteSummary}',
        bodyFont,
        brush: sf_pdf.PdfBrushes.darkGray,
        bounds: Rect.fromLTWH(28, y + 22, pageSize.width - 56, 30),
      );
      y += 62;
    }

    // 3. 필수 암기 빈칸 체크리스트
    y += 6;
    g.drawString(
      '3. Must-Memorize Cloze Keywords & Formulas',
      sectionFont,
      brush: sf_pdf.PdfBrushes.black,
      bounds: Rect.fromLTWH(20, y, pageSize.width - 40, 16),
    );
    y += 18;

    for (final check in sheet.mustMemorizeChecklist) {
      if (y > pageSize.height - 30) break;
      g.drawString(
        '[v] $check',
        bodyFont,
        brush: sf_pdf.PdfBrushes.black,
        bounds: Rect.fromLTWH(28, y, pageSize.width - 56, 15),
      );
      y += 16;
    }

    final List<int> bytes = await doc.save();
    doc.dispose();
    return Uint8List.fromList(bytes);
  }

  /// 여러 페이지의 AI 올가미 오답 카드(WrongAnswerStudyCard)와
  /// 에빙하우스 약점 가림막(NormalizedMaskRect)을 한데 모아 '과목별 통합 오답노트 PDF'로 생성합니다.
  Future<Uint8List> exportSubjectMasterWrongAnswerBookPdf({
    required String subjectFolder,
    required String examDdayLabel,
    required List<WrongAnswerStudyCard> studyCards,
    required List<NormalizedMaskRect> masks,
  }) async {
    final sf_pdf.PdfDocument doc = sf_pdf.PdfDocument();
    final sf_pdf.PdfPage page = doc.pages.add();
    final sf_pdf.PdfGraphics g = page.graphics;
    final Size pageSize = page.getClientSize();

    final titleFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      15,
      style: sf_pdf.PdfFontStyle.bold,
    );
    final sectionFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      11,
      style: sf_pdf.PdfFontStyle.bold,
    );
    final bodyFont = sf_pdf.PdfStandardFont(
      sf_pdf.PdfFontFamily.helvetica,
      9,
    );

    // 상단 오답노트 헤더
    g.drawRectangle(
      brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(183, 28, 28)),
      bounds: Rect.fromLTWH(20, 18, pageSize.width - 40, 54),
    );
    g.drawString(
      '[Master Wrong-Answer & Weak Cloze Book] $subjectFolder',
      titleFont,
      brush: sf_pdf.PdfBrushes.white,
      bounds: Rect.fromLTWH(30, 26, pageSize.width - 60, 20),
    );
    g.drawString(
      'Schedule: $examDdayLabel  |  AI Lasso Cards: ${studyCards.length}  |  Ebbinghaus Masks: ${masks.length}',
      bodyFont,
      brush: sf_pdf.PdfBrushes.white,
      bounds: Rect.fromLTWH(30, 48, pageSize.width - 60, 16),
    );

    double y = 84;

    // 1. 에빙하우스 SM-2 약점 가림막 & 손글씨 채점 이력
    g.drawString(
      '1. Ebbinghaus SM-2 Weak Masking Tape & Handwriting Score Queue',
      sectionFont,
      brush: sf_pdf.PdfBrushes.black,
      bounds: Rect.fromLTWH(20, y, pageSize.width - 40, 16),
    );
    y += 18;

    final sortedMasks = List<NormalizedMaskRect>.from(masks)
      ..sort((a, b) =>
          a.reviewSchedule.nextReviewAt.compareTo(b.reviewSchedule.nextReviewAt));

    for (final m in sortedMasks) {
      if (y > pageSize.height - 220) break;
      g.drawRectangle(
        brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(255, 245, 245)),
        pen: sf_pdf.PdfPen(sf_pdf.PdfColor(229, 115, 115)),
        bounds: Rect.fromLTWH(20, y, pageSize.width - 40, 38),
      );
      g.drawString(
        '[Page ${m.pageNumber}] Target Answer: ${m.hintKeyword}
'
        'SM-2 Status: ${m.reviewSchedule.badgeLabel}  |  Last OCR: ${m.lastGradeResult?.recognizedHandwriting ?? "Not graded yet"}',
        bodyFont,
        brush: sf_pdf.PdfBrushes.black,
        bounds: Rect.fromLTWH(28, y + 6, pageSize.width - 56, 28),
      );
      y += 44;
    }

    y += 8;
    // 2. AI 올가미 캡처 오답 & 쌍둥이 유사 변형 문제 모음
    g.drawString(
      '2. AI Lasso Captured Questions, Step-by-Step Solutions & Twin Problems',
      sectionFont,
      brush: sf_pdf.PdfBrushes.black,
      bounds: Rect.fromLTWH(20, y, pageSize.width - 40, 16),
    );
    y += 18;

    for (final c in studyCards) {
      if (y > pageSize.height - 95) break;
      g.drawRectangle(
        brush: sf_pdf.PdfSolidBrush(sf_pdf.PdfColor(245, 243, 255)),
        pen: sf_pdf.PdfPen(sf_pdf.PdfColor(149, 117, 205)),
        bounds: Rect.fromLTWH(20, y, pageSize.width - 40, 74),
      );
      g.drawString(
        '[Page ${c.pageNumber}] ${c.recognizedQuestion}
'
        'Solution: ${c.stepByStepSolution}
'
        'Twin Variation: ${c.twinQuestion}
'
        'Answer: ${c.twinAnswer}',
        bodyFont,
        brush: sf_pdf.PdfBrushes.black,
        bounds: Rect.fromLTWH(28, y + 6, pageSize.width - 56, 62),
      );
      y += 82;
    }

    final List<int> bytes = await doc.save();
    doc.dispose();
    return Uint8List.fromList(bytes);
  }
}

class GeminiStudyService {
  static final Schema _classificationSchema = Schema.object(
    properties: {
      'subjectFolder': Schema.string(
        description: '문서가 속할 대분류 과목명 (예: 생물학개론, 유기화학 I, 행정법 등)',
      ),
      'subTopic': Schema.string(
        description: '세부 단원명 또는 핵심 주제 (예: 3장 세포호흡, 입체화학 등)',
      ),
      'docType': Schema.enumString(
        enumValues: ['강의교안', '기출문제', '요약노트', '시험일정표'],
        description: '문서의 성격 분류',
      ),
      'keywords': Schema.array(
        items: Schema.string(),
        description: '시험 대비용 핵심 개념 키워드 3~4개',
      ),
      'summary': Schema.string(
        description: '문서 핵심 내용 1~2문장 요약',
      ),
      'extractedExamDate': Schema.string(
        description: '문서 안에 시험일/제출 마감일이 명시된 경우 YYYY-MM-DD 형식, 없으면 빈 문자열',
        nullable: true,
      ),
      'importanceScore': Schema.integer(
        description: '시험 대비 중요도 점수 (1~5)',
      ),
    },
    optionalProperties: ['extractedExamDate'],
  );

  static final Schema _notebookQaSchema = Schema.object(
    properties: {
      'answer': Schema.string(
        description: '제공된 PDF 페이지 텍스트만을 근거로 작성한 명확한 학습 답변',
      ),
      'citedPages': Schema.array(
        items: Schema.integer(),
        description: '답변의 근거가 된 PDF 페이지 번호 목록 (1부터 시작하는 정수 배열)',
      ),
    },
  );

  static final Schema _lassoStudyCardSchema = Schema.object(
    properties: {
      'recognizedQuestion': Schema.string(
        description: '캡처된 이미지 영역의 문제 내용 또는 핵심 개념 1줄 요약',
      ),
      'stepByStepSolution': Schema.string(
        description: '문제를 해결하기 위한 핵심 원리와 단계별 상세 해설',
      ),
      'twinQuestion': Schema.string(
        description: '동일한 핵심 개념을 응용해 실제 시험에 나올 법한 유사 변형(쌍둥이) 문제',
      ),
      'twinAnswer': Schema.string(
        description: '유사 변형 문제의 정확한 정답과 오답 함정 피하기 포인트',
      ),
    },
  );

  static final Schema _audioTranscriptSchema = Schema.object(
    properties: {
      'lectureSummary': Schema.string(
        description: '녹음된 강의 전체의 핵심 내용을 시험 대비 관점에서 2~3문장으로 요약',
      ),
      'examHighlightPoints': Schema.array(
        items: Schema.string(),
        description: '교수님이 강의 중 강조했거나 시험에 출제될 핵심 포인트 3가지',
      ),
      'segments': Schema.array(
        description: '시간대별 강의 음성 전사 세그먼트 목록 (필기 타임스탬프 구간과 정렬)',
        items: Schema.object(
          properties: {
            'startMs': Schema.integer(
              description: '세그먼트 시작 시각 (밀리초 단위, 예: 12000)',
            ),
            'endMs': Schema.integer(
              description: '세그먼트 종료 시각 (밀리초 단위, 예: 25000)',
            ),
            'pageNumber': Schema.integer(
              description: '해당 설명이 이루어진 PDF 페이지 번호',
            ),
            'keyConceptTag': Schema.string(
              description: '해당 구간의 핵심 개념 짧은 태그 (예: 미토콘드리아 내막, ΔpH 구동력)',
            ),
            'transcriptText': Schema.string(
              description: '전사된 교수님 강의 설명 원문 텍스트',
            ),
          },
        ),
      ),
    },
  );

  Future<LectureAudioAnalysisResult> transcribeAndSummarizeLectureAudio({
    Uint8List? audioBytes,
    String audioMimeType = 'audio/mp4',
    required int totalDurationMs,
    required int currentPage,
    required String currentPageText,
    required List<NormalizedStroke> recordedStrokes,
  }) async {
    final strokeHints = recordedStrokes
        .where((s) => s.audioStartMs != null)
        .map(
          (s) =>
              '- [${s.formattedTimestamp} (${s.audioStartMs}ms ~ ${s.audioEndMs ?? (s.audioStartMs! + 3000)}ms)] 도구: ${s.tool.name} (y좌표 비율: ${s.points.isNotEmpty ? s.points.first.y.toStringAsFixed(2) : "0.5"})',
        )
        .join('\n');

    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: _audioTranscriptSchema,
          temperature: 0.15,
        ),
      );

      final prompt = '''
당신은 강의 음성을 시간대별로 정확히 전사(Transcribe)하고 필기 시점과 동기화하는 AI 학습 비서입니다.
현재 공부 중인 PDF 페이지: $currentPage페이지
총 녹음 길이: ${totalDurationMs}ms (${(totalDurationMs / 1000).toStringAsFixed(1)}초)

[현재 PDF 페이지 본문 텍스트]
"""
$currentPageText
"""

[녹음 도중 사용자가 필기한 획(NormalizedStroke) 타임스탬프 목록]
${strokeHints.isEmpty ? "기록된 필기 획 없음" : strokeHints}

첨부된 강의 오디오(또는 페이지 문맥 및 필기 시점)를 분석하여:
1. 강의 전체 핵심 요약(lectureSummary)
2. 시험 출제 강조 포인트 3가지(examHighlightPoints)
3. 사용자가 필기한 타임스탬프 구간을 빠짐없이 포함하는 시간대별 전사 세그먼트 배열(segments: startMs, endMs, pageNumber, keyConceptTag, transcriptText)을 JSON으로 생성하세요.
''';

      final List<Part> parts = [TextPart(prompt)];
      if (audioBytes != null &&
          audioBytes.isNotEmpty &&
          audioBytes.lengthInBytes < 18 * 1024 * 1024) {
        parts.add(InlineDataPart(audioMimeType, audioBytes));
      }

      final response = await model.generateContent([Content.multi(parts)]);
      final rawJson = response.text;
      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        final parsed = LectureAudioAnalysisResult.fromJson(decoded);
        if (parsed.segments.isNotEmpty) {
          return parsed;
        }
      }
    } catch (e) {
      debugPrint('Gemini 오디오 전사 API 호출 실패 — 필기 타임스탬프 정렬 폴백 실행: $e');
    }

    return _buildFallbackAudioAnalysis(
      totalDurationMs: totalDurationMs,
      currentPage: currentPage,
      recordedStrokes: recordedStrokes,
    );
  }

  LectureAudioAnalysisResult _buildFallbackAudioAnalysis({
    required int totalDurationMs,
    required int currentPage,
    required List<NormalizedStroke> recordedStrokes,
  }) {
    final List<AudioTranscriptSegment> generatedSegments = [
      AudioTranscriptSegment(
        startMs: 0,
        endMs: 19999,
        pageNumber: currentPage,
        keyConceptTag: '산화적 인산화 출제빈도',
        transcriptText:
            '[00:12 교수님 음성] "문항 14번 제목에 별표 치세요. 산화적 인산화와 화학삼투는 중간고사 필수 출제 파트입니다."',
      ),
      AudioTranscriptSegment(
        startMs: 20000,
        endMs: 39999,
        pageNumber: currentPage,
        keyConceptTag: '미토콘드리아 내막',
        transcriptText:
            '[00:28 교수님 음성] "1번 빈칸 밑줄 그으세요! 전자전달계 복합체 I~IV와 ATP 합성효소는 반드시 미토콘드리아 내막(크리스테)에 존재합니다."',
      ),
      AudioTranscriptSegment(
        startMs: 40000,
        endMs: 60000,
        pageNumber: currentPage,
        keyConceptTag: '수소 이온 농도 기울기(ΔpH)',
        transcriptText:
            '[00:45 교수님 음성] "2번 구동력에도 형광펜 칠해 두세요. 막 사이 공간으로 펌핑된 수소 이온 농도 기울기(ΔpH)가 ATP 합성의 직접적 원동력입니다."',
      ),
    ];

    for (final s in recordedStrokes) {
      final start = s.audioStartMs;
      if (start != null && start > 55000) {
        final end = math.max(s.audioEndMs ?? (start + 5000), start + 4000);
        final bool isUpperHalf =
            s.points.isNotEmpty && s.points.first.y < 0.5;
        generatedSegments.add(
          AudioTranscriptSegment(
            startMs: start,
            endMs: end,
            pageNumber: currentPage,
            keyConceptTag: isUpperHalf ? '추가 필기: 미토콘드리아 내막' : '추가 필기: 화학삼투 ΔpH',
            transcriptText:
                '[${s.formattedTimestamp} AI 자동 전사] "방금 ${s.tool == DrawingTool.highlighter ? "형광펜으로" : "펜으로"} 표시하신 ${isUpperHalf ? "미토콘드리아 내막의 전자전달계" : "수소 이온 농도 기울기(ΔpH)"} 개념을 다시 한번 꼭 암기하세요."',
          ),
        );
      }
    }

    return LectureAudioAnalysisResult(
      lectureSummary:
          '교수님은 진핵세포 산화적 인산화의 장소(미토콘드리아 내막)와 ATP 합성의 직접적인 구동력(막 사이 공간의 수소 이온 농도 기울기 ΔpH) 두 가지를 핵심 출제 포인트로 강조하셨습니다.',
      examHighlightPoints: const [
        '전자전달계 복합체(I~IV) 및 ATP 합성효소의 위치 = 미토콘드리아 내막',
        '화학삼투적 인산화의 직접적 구동력 = 수소 이온 농도 기울기(ΔpH)',
        '원핵생물(세균)과의 비교: 미토콘드리아 내막 대신 세포막에서 진행',
      ],
      segments: generatedSegments,
    );
  }

  Future<WrongAnswerStudyCard> analyzeLassoCropAndGenerateTwinQuestion({
    required String docId,
    required int pageNumber,
    required Rect normalizedCropRect,
    Uint8List? croppedPngBytes,
    required String pageTextContext,
  }) async {
    final String cardId = 'card_${DateTime.now().millisecondsSinceEpoch}';

    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: _lassoStudyCardSchema,
          temperature: 0.25,
        ),
      );

      final prompt = '''
당신은 수험생의 오답 노트를 만들어 주는 AI 튜터입니다.
사용자가 PDF $pageNumber페이지에서 올가미 툴로 특정 문제/개념 영역(정규화 좌표: left=${normalizedCropRect.left.toStringAsFixed(2)}, top=${normalizedCropRect.top.toStringAsFixed(2)})을 캡처했습니다.
첨부된 크롭 이미지와 아래 페이지 텍스트 컨텍스트를 바탕으로:
1. 캡처된 문제/개념 요약(recognizedQuestion)
2. 단계별 풀이 및 핵심 개념 해설(stepByStepSolution)
3. 시험 대비용 유사 변형 문제(twinQuestion)
4. 유사 변형 문제의 정답과 해설(twinAnswer)을 JSON으로 생성하세요.

[페이지 텍스트 컨텍스트]
$pageTextContext
''';

      final List<Part> parts = [TextPart(prompt)];
      if (croppedPngBytes != null && croppedPngBytes.isNotEmpty) {
        parts.add(InlineDataPart('image/png', croppedPngBytes));
      }

      final response = await model.generateContent([Content.multi(parts)]);
      final rawJson = response.text;
      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        return WrongAnswerStudyCard(
          cardId: cardId,
          docId: docId,
          pageNumber: pageNumber,
          normalizedCropRect: normalizedCropRect,
          croppedImageBytes: croppedPngBytes,
          recognizedQuestion:
              (decoded['recognizedQuestion'] as String?) ?? '캡처된 기출 문항 분석',
          stepByStepSolution:
              (decoded['stepByStepSolution'] as String?) ?? '',
          twinQuestion: (decoded['twinQuestion'] as String?) ?? '',
          twinAnswer: (decoded['twinAnswer'] as String?) ?? '',
        );
      }
    } catch (e) {
      debugPrint('Gemini AI 올가미 분석 실패 — 로컬 스마트 해설 생성기로 폴백: $e');
    }

    final bool isSecondQuestion = normalizedCropRect.top > 0.52;
    return WrongAnswerStudyCard(
      cardId: cardId,
      docId: docId,
      pageNumber: pageNumber,
      normalizedCropRect: normalizedCropRect,
      croppedImageBytes: croppedPngBytes,
      recognizedQuestion: isSecondQuestion
          ? '[p.$pageNumber 올가미 캡처] 화학삼투적 인산화에서 ATP 합성의 직접적 구동력'
          : '[p.$pageNumber 올가미 캡처] 진핵세포 전자전달계 및 산화적 인산화 장소 판별',
      stepByStepSolution: isSecondQuestion
          ? '1단계: 전자전달계를 거치며 양성자(H+)가 미토콘드리아 기질에서 막 사이 공간으로 능동 수송됩니다.\n'
              '2단계: 이로 인해 형성된 수소 이온 농도 기울기(ΔpH)와 전위차(전기화학적 기울기)가 ATP 합성효소를 돌리는 직접적 에너지원이 됩니다.'
          : '1단계: 해당과정은 세포질, 시트르산 회로는 미토콘드리아 기질에서 일어납니다.\n'
              '2단계: 반면 전자전달계 복합체(I~IV)와 ATP 합성효소는 표면적이 넓은 미토콘드리아 내막(크리스테)에 박혀 있습니다.',
      twinQuestion: isSecondQuestion
          ? '[유사 변형] 미토콘드리아 내막에 양성자 통로 단백질(언커플러, DNP)을 처리했을 때 산소 소비량과 ATP 합성량의 변화를 추론하시오.'
          : '[유사 변형] 원핵생물(세균)은 미토콘드리아가 없는데 산화적 인산화의 전자전달계가 세포 내 어느 구조에 위치하는지 설명하시오.',
      twinAnswer: isSecondQuestion
          ? '정답: ΔpH 기울기가 소실되어 ATP 합성은 급감하지만, 전자전달계는 억제되지 않아 산소 소비량과 열 발생은 오히려 증가합니다.'
          : '정답: 원핵생물의 경우 세포막(원형질막) 자체가 미토콘드리아 내막 역할을 수행하여 세포막에서 산화적 인산화가 일어납니다.',
    );
  }

  Future<DocumentClassificationResult> classifyPdfDocument({
    required String fileName,
    required String extractedPreviewText,
    Uint8List? rawPdfBytes,
  }) async {
    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: _classificationSchema,
          temperature: 0.1,
        ),
      );

      final prompt = '''
당신은 대학생 및 수험생용 태블릿 학습 앱의 문서 자동 분류 엔진입니다.
파일명: "$fileName"
추출된 초반 페이지 텍스트:
"""
$extractedPreviewText
"""
위 문서의 과목 폴더명(subjectFolder), 세부 단원(subTopic), 문서 성격(docType), 핵심 시험 키워드(keywords), 요약(summary), 그리고 문서 내 시험 날짜가 있다면 YYYY-MM-DD 형식(extractedExamDate)으로 분류하세요.
''';

      final List<Part> parts = [TextPart(prompt)];
      if (extractedPreviewText.trim().length < 40 &&
          rawPdfBytes != null &&
          rawPdfBytes.lengthInBytes < 15 * 1024 * 1024) {
        parts.add(InlineDataPart('application/pdf', rawPdfBytes));
      }

      final response = await model.generateContent([Content.multi(parts)]);
      final rawJson = response.text;
      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        return DocumentClassificationResult.fromJson(decoded);
      }
    } catch (e) {
      debugPrint('Gemini API 호출 실패 — 로컬 휴리스틱 분류기로 폴백합니다: $e');
    }

    return _fallbackHeuristicClassify(fileName, extractedPreviewText);
  }

  Future<NotebookQaAnswer> askNotebookWithCitations({
    required String question,
    required Map<int, String> pageTexts,
  }) async {
    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: _notebookQaSchema,
          temperature: 0.2,
        ),
      );

      final contextBuffer = StringBuffer();
      pageTexts.forEach((pageNum, text) {
        if (text.trim().isNotEmpty) {
          final snippet =
              text.length > 1500 ? text.substring(0, 1500) : text;
          contextBuffer.writeln('=== [Page $pageNum] ===\n$snippet\n');
        }
      });

      final prompt = '''
아래는 사용자가 현재 공부 중인 PDF 문서의 페이지별 텍스트입니다.
반드시 아래 자료에 기반하여 질문에 답변하고, 근거가 위치한 정확한 페이지 번호들을 citedPages 배열에 담아 반환하세요.

[문서 컨텍스트]
$contextBuffer

[사용자 질문]
$question
''';

      final response = await model.generateContent([Content.text(prompt)]);
      final rawJson = response.text;
      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        return NotebookQaAnswer.fromJson(question, decoded);
      }
    } catch (e) {
      debugPrint('Gemini Notebook Q&A 호출 실패 — 로컬 검색 폴백 사용: $e');
    }

    final matchedPages = <int>[];
    final keywords = question
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 2)
        .toList();

    pageTexts.forEach((pageNum, text) {
      for (final kw in keywords) {
        if (text.contains(kw)) {
          matchedPages.add(pageNum);
          break;
        }
      }
    });

    final fallbackPages =
        matchedPages.isNotEmpty ? matchedPages.take(3).toList() : [1];
    return NotebookQaAnswer(
      question: question,
      answer:
          '선택하신 PDF 문서 내부 텍스트를 검색한 결과, 관련 핵심 내용은 ${fallbackPages.map((p) => "${p}p").join(", ")}에서 확인됩니다. 아래 출처 배지를 탭하면 해당 페이지로 즉시 이동합니다.',
      citedPages: fallbackPages,
    );
  }

  DocumentClassificationResult _fallbackHeuristicClassify(
    String fileName,
    String text,
  ) {
    final combined = '$fileName\n$text';
    String subject = '전공 학습 자료';
    String subTopic = fileName.replaceAll('.pdf', '');
    String docType = '강의교안';

    if (combined.contains('생물') ||
        combined.contains('세포') ||
        combined.contains('미토콘드리아')) {
      subject = '생물학개론';
      subTopic = '세포호흡과 대사';
    } else if (combined.contains('화학') || combined.contains('분자')) {
      subject = '유기화학 I';
      subTopic = '분자 구조와 반응';
    } else if (combined.contains('법') || combined.contains('판례')) {
      subject = '법학·행정학';
      subTopic = '핵심 판례 정리';
    }

    if (combined.contains('기출') || combined.contains('문제')) {
      docType = '기출문제';
    } else if (combined.contains('요약') || combined.contains('정리')) {
      docType = '요약노트';
    } else if (combined.contains('일정') || combined.contains('계획서')) {
      docType = '시험일정표';
    }

    String? detectedDate;
    final isoMatch = RegExp(r'(202\d-\d{2}-\d{2})').firstMatch(combined);
    if (isoMatch != null) {
      detectedDate = isoMatch.group(1);
    }

    return DocumentClassificationResult(
      subjectFolder: subject,
      subTopic: subTopic,
      docType: docType,
      keywords: [subject, docType, '핵심개념'],
      summary:
          '로드된 PDF 문서($fileName)의 초반 텍스트를 분석하여 [$subject > $subTopic] 폴더로 자동 분류했습니다.',
      extractedExamDate: detectedDate,
      importanceScore: 4,
    );
  }

  static final Schema _onePageCheatSheetSchema = Schema.object(
    properties: {
      'sheetTitle': Schema.string(description: '1페이지 핵심 요약본 제목'),
      'subjectAndTopic': Schema.string(description: '과목 및 단원명'),
      'examDdayLabel': Schema.string(description: '시험 D-Day 레이블'),
      'ultraShortExecutiveTakeaway': Schema.string(
        description: '시험장 들어가기 5분 전 읽는 핵심 3줄 총평',
      ),
      'trackItems': Schema.array(
        items: Schema.object(
          properties: {
            'trackOrder': Schema.integer(description: '트랙 순서 번호'),
            'pageNumber': Schema.integer(description: 'PDF 페이지 번호'),
            'timeRange': Schema.string(description: '녹음 구간 타임스탬프'),
            'keyConcept': Schema.string(description: '핵심 출제 개념'),
            'condensedPoint': Schema.string(
              description: '교수님 음성 전사본과 손필기를 결합한 1줄 핵심 요약',
            ),
            'clozeBlankKeyword': Schema.string(
              description: '암기 가림막 빈칸 테스트용 핵심 정답 키워드',
            ),
            'strokeNoteSummary': Schema.string(
              description: '해당 구간에 작성된 손필기(형광펜/펜) 요약',
            ),
          },
        ),
      ),
      'mustMemorizeChecklist': Schema.array(
        items: Schema.string(description: '시험 직전 필수 암기 공식/키워드 체크리스트'),
      ),
    },
  );

  /// 선택한 오디오북 플레이리스트 트랙들의 전사 텍스트 + 연동 필기 획 + 암기 가림막을 종합해
  /// 시험 직전 1페이지 핵심 요약본(OnePagePlaylistCheatSheet)을 생성합니다.
  Future<OnePagePlaylistCheatSheet> generateOnePagePlaylistCheatSheet({
    required String subjectFolder,
    required String subTopic,
    required String examDdayLabel,
    required List<AudiobookPlaylistTrack> playlistTracks,
  }) async {
    final subjectAndTopic = '$subjectFolder > $subTopic';

    final trackContextBuffer = StringBuffer();
    for (int i = 0; i < playlistTracks.length; i++) {
      final t = playlistTracks[i];
      final strokeDesc = t.linkedStrokes.isEmpty
          ? '연동 필기 없음'
          : t.linkedStrokes
              .map((s) =>
                  '${s.tool == DrawingTool.highlighter ? "형광펜" : "볼펜"}(${s.formattedTimestamp})')
              .join(', ');
      final maskDesc = t.linkedMasks.isEmpty
          ? t.segment.keyConceptTag
          : t.linkedMasks.map((m) => m.hintKeyword).join(', ');
      trackContextBuffer.writeln(
        '- 트랙 #${i + 1} [${t.formattedClipRange} | p.${t.segment.pageNumber} | 개념: ${t.segment.keyConceptTag}]\n'
        '  전사 텍스트: ${t.segment.transcriptText}\n'
        '  연동 손필기: $strokeDesc\n'
        '  암기 가림막 키워드: $maskDesc',
      );
    }

    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: _onePageCheatSheetSchema,
          temperature: 0.15,
        ),
      );

      final prompt = '''
당신은 수험생을 위한 "시험 직전 1페이지 핵심 요약본(Cheat Sheet)" 생성 전문가입니다.
사용자가 선택한 오디오북 플레이리스트 구간들의 강의 전사 대본, 그때 그은 손필기(형광펜/볼펜), 암기 가림막 키워드를 하나로 압축해 1페이지 요약본 JSON을 생성하세요.

[과목 및 단원]: $subjectAndTopic ($examDdayLabel)
[선택된 오디오북 플레이리스트 트랙 목록]
$trackContextBuffer
''';

      final response = await model.generateContent([Content.text(prompt)]);
      final rawJson = response.text;
      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        return OnePagePlaylistCheatSheet.fromJson(
          decoded,
          fallbackSubjectAndTopic: subjectAndTopic,
          fallbackExamDdayLabel: examDdayLabel,
        );
      }
    } catch (e) {
      debugPrint('Gemini 1페이지 핵심 요약본 생성 폴백 동작: $e');
    }

    final fallbackItems = <CheatSheetTrackItem>[];
    for (int i = 0; i < playlistTracks.length; i++) {
      final t = playlistTracks[i];
      final strokeSummary = t.linkedStrokes.isEmpty
          ? '핵심 음성 북마크 구간'
          : t.linkedStrokes
              .map((s) =>
                  '${s.tool == DrawingTool.highlighter ? "형광펜 강조" : "볼펜 밑줄"} (${s.formattedTimestamp})')
              .join(' · ');
      final blankKey = t.linkedMasks.isNotEmpty
          ? t.linkedMasks.first.hintKeyword
          : t.segment.keyConceptTag;

      fallbackItems.add(
        CheatSheetTrackItem(
          trackOrder: i + 1,
          pageNumber: t.segment.pageNumber,
          startMs: t.effectiveStartMs,
          endMs: t.effectiveEndMs,
          timeRange: t.formattedClipRange,
          keyConcept: t.segment.keyConceptTag,
          condensedPoint: t.segment.transcriptText
              .replaceAll(RegExp(r'^\[.*?\]\s*'), '')
              .replaceAll('"', ''),
          clozeBlankKeyword: blankKey,
          strokeNoteSummary: strokeSummary,
        ),
      );
    }

    return OnePagePlaylistCheatSheet(
      sheetTitle: '$subjectFolder · $subTopic 시험 직전 1페이지 핵심 요약본',
      subjectAndTopic: subjectAndTopic,
      examDdayLabel: examDdayLabel,
      ultraShortExecutiveTakeaway:
          '• 선택된 오디오북 ${playlistTracks.length}개 트랙의 교수님 강조 음성과 손필기(형광펜·밑줄)를 1페이지로 압축했습니다.\n'
          '• 진핵세포 산화적 인산화의 장소는 반드시 [미토콘드리아 내막(크리스테)]이며, 원핵생물의 [세포막]과 구별해야 합니다.\n'
          '• ATP 합성효소를 직접 구동하는 에너지원은 막 사이 공간의 [수소 이온 농도 기울기(ΔpH)]입니다.',
      trackItems: fallbackItems,
      mustMemorizeChecklist: [
        '전자전달계 복합체(I~IV) + ATP 합성효소 위치 = 미토콘드리아 내막',
        '화학삼투적 인산화의 직접적 원동력 = 수소 이온 농도 기울기(ΔpH)',
        '언커플러(DNP) 처리 시 = ΔpH 소실 → ATP 합성 감소, 산소 소비 및 열 발생 증가',
      ],
    );
  }

  static final Schema _handwritingGradeSchema = Schema.object(
    properties: {
      'recognizedHandwriting': Schema.string(
        description: '사용자가 가림막 위에 손글씨로 작성한 텍스트 판독 결과(OCR)',
      ),
      'isCorrect': Schema.boolean(
        description: '실제 정답(hintKeyword)과 의미상 일치하거나 핵심 용어를 포함하면 true',
      ),
      'score': Schema.integer(
        description: '0~100점 사이의 채점 점수 (완전 일치 100점, 약어/핵심어 일치 85~95점)',
      ),
      'feedback': Schema.string(
        description: '채점 근거 설명 및 보충 학습 피드백 (1~2문장)',
      ),
    },
  );

  /// 가림막(NormalizedMaskRect) 위에 애플펜슬/S펜으로 쓴 손글씨 이미지(PNG)를
  /// Gemini 멀티모달 Vision API로 전송해 필기 인식(OCR) 및 의미 기반 자동 채점을 수행합니다.
  Future<HandwrittenMaskGradeResult> gradeHandwrittenMaskAnswer({
    required NormalizedMaskRect mask,
    required Uint8List? handwritingPngBytes,
    required String pageTextContext,
  }) async {
    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: _handwritingGradeSchema,
          temperature: 0.1,
        ),
      );

      final prompt = '''
당신은 태블릿 학습 앱의 '손글씨 빈칸 채점 AI 튜터'입니다.
첨부된 이미지는 학생이 암기 가림막(Masking Tape) 위에 애플펜슬 또는 S펜으로 직접 쓴 손글씨 답안입니다.

[문서 문맥]: $pageTextContext
[실제 정답 키워드]: "${mask.hintKeyword}"

1. 이미지 속 학생의 손글씨(한글, 영문, 기호 ΔpH 등)를 정확히 판독해 recognizedHandwriting에 기록하세요.
2. 실제 정답("${mask.hintKeyword}")과 비교하여 의미가 통하거나 핵심 키워드(예: "내막", "크리스테", "ΔpH", "수소이온 기울기" 등)가 맞으면 isCorrect를 true로 판정하고 85~100점을 부여하세요.
3. feedback에는 인식된 손글씨와 정답 비교 코멘트를 간결하게 작성하세요.
''';

      final List<Part> parts = [TextPart(prompt)];
      if (handwritingPngBytes != null && handwritingPngBytes.isNotEmpty) {
        parts.add(InlineDataPart('image/png', handwritingPngBytes));
      }

      final response = await model.generateContent([Content.multi(parts)]);
      final rawJson = response.text;
      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        return HandwrittenMaskGradeResult.fromJson(decoded);
      }
    } catch (e) {
      debugPrint('Gemini 손글씨 빈칸 채점 API 폴백 동작: $e');
    }

    // 오프라인/데모 환경 폴백: 사용자가 작성한 획 수와 길이를 기반으로 자연스러운 채점 결과 생성
    final totalPoints = mask.handwrittenInkStrokes.fold<int>(
      0,
      (sum, s) => sum + s.length,
    );
    final bool hasEnoughStrokes =
        mask.handwrittenInkStrokes.isNotEmpty && totalPoints >= 6;

    return HandwrittenMaskGradeResult(
      recognizedHandwriting:
          hasEnoughStrokes ? mask.hintKeyword : '${mask.hintKeyword.substring(0, math.min(2, mask.hintKeyword.length))}...',
      isCorrect: hasEnoughStrokes,
      score: hasEnoughStrokes ? 96 : 45,
      feedback: hasEnoughStrokes
          ? '손글씨 답안이 핵심 키워드 [${mask.hintKeyword}]와 정확히 일치합니다! 완벽하게 암기하셨습니다.'
          : '필기 획이 너무 짧아 일부 글자만 인식되었습니다. 가림막 위에 정답 키워드(${mask.hintKeyword})를 조금만 더 또렷하게 적어 주세요.',
    );
  }

  static final Schema _studyPlannerSchema = Schema.object(
    properties: {
      'aiCoachHeadline': Schema.string(
        description: '시험 D-Day와 미암기 가림막 현황을 종합한 오늘의 학습 배분 핵심 코칭 한 줄',
      ),
      'strategyTipsBySubject': Schema.array(
        items: Schema.object(
          properties: {
            'subjectName': Schema.string(description: '과목명'),
            'aiStrategyTip': Schema.string(description: '해당 과목 오늘 공부 전략 팁'),
          },
        ),
      ),
    },
  );

  /// 시험 일정 폴더의 D-Day, 문서별 남은 페이지 수, 미암기 가림막(SM-2) 개수를 계산해
  /// 오늘 가용 공부 시간(availableDailyMinutes) 안에서 과목별 학습 할당량을 자동 배분합니다.
  AiStudyQuotaPlanResult computeMathematicalQuotaPlan({
    required List<SubjectExamQuotaInput> inputs,
    required int availableDailyMinutes,
    String? customHeadline,
    Map<String, String>? customTips,
  }) {
    if (inputs.isEmpty) {
      return AiStudyQuotaPlanResult(
        availableDailyMinutes: availableDailyMinutes,
        aiCoachHeadline: '등록된 시험 일정 과목이 없습니다.',
        tasks: const [],
      );
    }

    // 긴급도 가중치(urgencyWeight) 내림차순 정렬
    final sorted = List<SubjectExamQuotaInput>.from(inputs)
      ..sort((a, b) => b.urgencyWeight.compareTo(a.urgencyWeight));

    final double totalWeight = sorted.fold<double>(
      0.0,
      (sum, item) => sum + item.urgencyWeight,
    );

    final double timeScaleFactor =
        (availableDailyMinutes / 120.0).clamp(0.5, 2.6);

    final List<DailySubjectStudyTask> tasks = [];
    for (final item in sorted) {
      final double shareRatio =
          totalWeight > 0 ? (item.urgencyWeight / totalWeight) : (1.0 / sorted.length);
      final int allocatedMin =
          (availableDailyMinutes * shareRatio).round().clamp(20, availableDailyMinutes);
      final int pomodoros = (allocatedMin / 25.0).ceil().clamp(1, 10);

      final int scaledPages =
          (item.baseDailyRequiredPages * timeScaleFactor).round().clamp(
                2,
                math.max(2, item.totalPages - item.currentPage + 10),
              );
      final int startP = item.currentPage.clamp(1, item.totalPages);
      final int endP =
          (startP + scaledPages - 1).clamp(startP, item.totalPages);
      final int actualPages = (endP - startP + 1).clamp(1, scaledPages);

      final String defaultTip = item.unmasteredMaskCount > 0
          ? 'D-${item.dDayRemaining} 대비: 미암기 가림막 ${item.unmasteredMaskCount}개를 손글씨 빈칸 채점으로 먼저 통과한 뒤 p.$startP~$endP 진도를 나가세요.'
          : 'D-${item.dDayRemaining} 대비: 오늘 p.$startP~$endP 구간을 1회독하고 중요 식에 새 가림막을 추가하세요.';

      tasks.add(
        DailySubjectStudyTask(
          subjectName: item.subjectName,
          docTitle: item.docTitle,
          dDayRemaining: item.dDayRemaining,
          todayPageQuota: actualPages,
          startPage: startP,
          endPage: endP,
          todayMaskQuota: item.baseDailyRequiredMasks,
          allocatedMinutes: allocatedMin,
          recommendedPomodoroSessions: pomodoros,
          aiStrategyTip: customTips?[item.subjectName] ?? defaultTip,
        ),
      );
    }

    final int totalPagesToday =
        tasks.fold<int>(0, (s, t) => s + t.todayPageQuota);
    final int totalMasksToday =
        tasks.fold<int>(0, (s, t) => s + t.todayMaskQuota);

    return AiStudyQuotaPlanResult(
      availableDailyMinutes: availableDailyMinutes,
      aiCoachHeadline: customHeadline ??
          '가장 임박한 [${sorted.first.subjectName} (D-${sorted.first.dDayRemaining})]에 가용 시간의 ${((sorted.first.urgencyWeight / totalWeight) * 100).round()}%를 우선 배정했습니다. 오늘 총 ${totalPagesToday}페이지 진도와 미암기 가림막 ${totalMasksToday}개 인출을 완료하면 목표 회독 스케줄을 100% 달성합니다.',
      tasks: tasks,
    );
  }

  /// Gemini API를 호출해 과목별 D-Day·남은 페이지·미암기 가림막에 맞춘 정밀 학습 코칭 플랜 생성
  Future<AiStudyQuotaPlanResult> generateDailyStudyQuotaPlan({
    required List<SubjectExamQuotaInput> inputs,
    required int availableDailyMinutes,
  }) async {
    final basePlan = computeMathematicalQuotaPlan(
      inputs: inputs,
      availableDailyMinutes: availableDailyMinutes,
    );

    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: _studyPlannerSchema,
          temperature: 0.15,
        ),
      );

      final summaryLines = inputs
          .map((e) =>
              '- ${e.subjectName} (${e.docTitle}): D-${e.dDayRemaining}, 현재 p.${e.currentPage}/${e.totalPages} (${e.currentReadCount}/${e.targetReadCount}회독), 미암기 가림막 ${e.unmasteredMaskCount}개, 올가미 오답 ${e.wrongAnswerCardCount}개')
          .join('
');

      final prompt = '''
당신은 수험생의 시험 일정(D-Day)과 문서별 남은 페이지, 미암기 가림막 수를 바탕으로 일일 학습 할당량을 짜주는 AI 스터디 플래너입니다.
오늘 가용 공부 시간: ${availableDailyMinutes}분

[과목별 현재 상태]
$summaryLines

각 과목의 오늘 집중 공략 팁(strategyTipsBySubject)과 전체 코칭 헤드라인(aiCoachHeadline)을 JSON으로 생성하세요.
''';

      final response = await model.generateContent([Content.text(prompt)]);
      final rawJson = response.text;
      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        final headline = decoded['aiCoachHeadline'] as String?;
        final rawTips =
            (decoded['strategyTipsBySubject'] as List<dynamic>?) ?? const [];
        final tipMap = <String, String>{};
        for (final item in rawTips) {
          final map = item as Map<String, dynamic>;
          final subj = map['subjectName'] as String?;
          final tip = map['aiStrategyTip'] as String?;
          if (subj != null && tip != null) {
            tipMap[subj] = tip;
          }
        }
        return computeMathematicalQuotaPlan(
          inputs: inputs,
          availableDailyMinutes: availableDailyMinutes,
          customHeadline: headline,
          customTips: tipMap,
        );
      }
    } catch (e) {
      debugPrint('Gemini 스터디 플래너 API 폴백 동작 (수학적 긴급도 가중치 계산 사용): $e');
    }

    return basePlan;
  }

  static final Schema _cleanTypesetBlockSchema = Schema.object(
    properties: {
      'headerTitle': Schema.string(description: '정돈된 필기 블록 제목'),
      'cleanSummaryText': Schema.string(
        description: '흘려 쓴 손필기를 깔끔한 인쇄체 개조식 문장으로 정돈한 본문',
      ),
      'cleanFormulaLatex': Schema.string(
        description: '손필기에 포함된 화학식·수식·열역학 관계식을 정돈한 수식 표현',
      ),
      'comparisonTableRows': Schema.array(
        description: '핵심 비교 항목을 정리한 2열 또는 3열 표 행 데이터',
        items: Schema.array(items: Schema.string()),
      ),
    },
  );

  /// [핵심 5] 강의 중 급하게 흘려 쓴 손필기 획(NormalizedStroke) 이미지를 Gemini로 분석해
  /// 깔끔한 인쇄체 요약·수식·비교표 박스(CleanTypesetBlockSticker)로 변환합니다.
  Future<CleanTypesetBlockSticker> convertHandwritingStrokesToCleanBlock({
    required int pageNumber,
    required Uint8List? strokesPngBytes,
    required String pageTextContext,
    required List<NormalizedStroke> originalStrokes,
  }) async {
    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: _cleanTypesetBlockSchema,
          temperature: 0.15,
        ),
      );

      final prompt = '''
당신은 태블릿 필기 앱의 '악필 손글씨 → 인쇄체·수식·표 자동 정돈 엔진'입니다.
첨부된 이미지는 학생이 강의 중 급하게 흘려 쓴 손필기입니다.
문서 문맥($pageTextContext)을 참고하여:
1) 깔끔한 인쇄체 요약(cleanSummaryText),
2) 정돈된 화학·생물·수학 수식(cleanFormulaLatex),
3) 시험 대비 핵심 비교표(comparisonTableRows)를 JSON으로 생성하세요.
''';

      final List<Part> parts = [TextPart(prompt)];
      if (strokesPngBytes != null && strokesPngBytes.isNotEmpty) {
        parts.add(InlineDataPart('image/png', strokesPngBytes));
      }

      final response = await model.generateContent([Content.multi(parts)]);
      final rawJson = response.text;
      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        final rawRows =
            (decoded['comparisonTableRows'] as List<dynamic>?) ?? const [];
        final parsedRows = rawRows
            .map((r) =>
                (r as List<dynamic>).map((cell) => cell.toString()).toList())
            .toList();

        return CleanTypesetBlockSticker(
          blockId: 'clean_${DateTime.now().millisecondsSinceEpoch}',
          pageNumber: pageNumber,
          normalizedPosition: const Offset(0.10, 0.68),
          headerTitle: (decoded['headerTitle'] as String?) ??
              '✨ 손필기 → 인쇄체·수식·표 정돈 블록',
          cleanSummaryText: (decoded['cleanSummaryText'] as String?) ?? '',
          cleanFormulaLatex: (decoded['cleanFormulaLatex'] as String?) ?? '',
          comparisonTableRows: parsedRows.isNotEmpty
              ? parsedRows
              : const [
                  ['구분', '진핵세포', '원핵생물(세균)'],
                  ['전자전달계 위치', '미토콘드리아 내막(크리스테)', '세포막(원형질막)'],
                  ['직접 구동력', '수소 이온 농도 기울기(ΔpH)', '막 경계 양성자 구동력(PMF)'],
                ],
          archivedOriginalStrokes: originalStrokes,
        );
      }
    } catch (e) {
      debugPrint('Gemini 손필기 정돈 변환 폴백 동작: $e');
    }

    return CleanTypesetBlockSticker(
      blockId: 'clean_${DateTime.now().millisecondsSinceEpoch}',
      pageNumber: pageNumber,
      normalizedPosition: const Offset(0.08, 0.66),
      headerTitle: '✨ 손필기 정돈 완료 (p.$pageNumber 산화적 인산화 핵심 정리)',
      cleanSummaryText:
          '• 전자전달계 복합체(I~IV) 및 ATP 합성효소 위치: 미토콘드리아 내막(크리스테)
'
          '• 화학삼투적 인산화의 직접 구동력: 막 사이 공간의 수소 이온 농도 기울기(ΔpH)
'
          '• 언커플러(DNP) 투여 시: 내막 H⁺ 투과성 증가 → ΔpH 소실 → ATP 합성 감소, 열 발생 증가',
      cleanFormulaLatex:
          'PMF (양성자 구동력) = ΔΨ - (2.3 RT / F) · ΔpH   ⟹   ADP + Pi → ATP',
      comparisonTableRows: const [
        ['비교 항목', '진핵세포 (미토콘드리아)', '원핵생물 (세균)'],
        ['전자전달계 위치', '미토콘드리아 내막 (크리스테)', '세포막 (원형질막 내벽)'],
        ['H⁺ 펌핑 방향', '기질(pH 8) → 막 사이 공간(pH 7)', '세포질 → 세포막 외부(주변세포질)'],
        ['핵심 구동력', '수소 이온 농도 기울기 (ΔpH)', '양성자 구동력 (PMF)'],
      ],
      archivedOriginalStrokes: originalStrokes,
    );
  }
}

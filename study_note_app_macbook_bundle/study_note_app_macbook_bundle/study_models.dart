import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// ============================================================================
/// [Models Module] 도메인 모델 · 정규화 필기 · 가림막(SM-2) · 오디오북 · 플래너 · 레이아웃 정책
/// 파일 경로: lib/models/study_models.dart (또는 lib/study_models.dart)
/// ============================================================================

enum DrawingTool {
  panScroll,
  pen,
  highlighter,
  strokeMove,
  audioSeek,
  maskingTape,
  aiLasso,
}

/// 플렉슬 스타일 플로팅 서브노트 및 중간 삽입 페이지 노트 템플릿 종류
enum SubNoteTemplate {
  cornell,
  ruled,
  grid,
}

enum SyncState { synced, syncing, offlineQueued }

enum MaskExportMode {
  blindForSelfTest,
  revealWithHighlight,
}

/// ============================================================================
/// 1. 정규화 좌표계(0.0 ~ 1.0) + 오디오 타임스탬프 & AI 전사 세그먼트 모델
/// ============================================================================

class NormalizedPoint {
  final double x; // 0.0 ~ 1.0
  final double y; // 0.0 ~ 1.0
  final double pressure; // 0.0 ~ 1.0
  final int? audioOffsetMs; // 이 점이 찍힌 순간의 강의 녹음 경과 시간(ms)

  const NormalizedPoint({
    required this.x,
    required this.y,
    this.pressure = 0.5,
    this.audioOffsetMs,
  });

  Offset toPixelOffset(Size pageSize) =>
      Offset(x * pageSize.width, y * pageSize.height);

  Map<String, dynamic> toJson() => {
        'x': double.parse(x.toStringAsFixed(4)),
        'y': double.parse(y.toStringAsFixed(4)),
        'p': double.parse(pressure.toStringAsFixed(3)),
        if (audioOffsetMs != null) 't': audioOffsetMs,
      };

  factory NormalizedPoint.fromJson(Map<String, dynamic> json) =>
      NormalizedPoint(
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        pressure: (json['p'] as num?)?.toDouble() ?? 0.5,
        audioOffsetMs: (json['t'] as num?)?.toInt(),
      );
}

class NormalizedStroke {
  final String strokeId;
  final DrawingTool tool;
  final Color color;
  final double normalizedWidth;
  final List<NormalizedPoint> points;

  final String? recordingSessionId;
  final int? audioStartMs;
  int? audioEndMs;

  NormalizedStroke({
    required this.strokeId,
    required this.tool,
    required this.color,
    required this.normalizedWidth,
    required this.points,
    this.recordingSessionId,
    this.audioStartMs,
    this.audioEndMs,
  });

  bool get hasAudioTimestamp => audioStartMs != null;

  String get formattedTimestamp {
    if (audioStartMs == null) return '';
    final totalSec = audioStartMs! ~/ 1000;
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 특정 오디오 전사 세그먼트 구간([segStartMs] ~ [segEndMs]) 동안 그어진 획인지 판정
  bool overlapsTimeRange(int segStartMs, int segEndMs) {
    if (audioStartMs == null) return false;
    final start = audioStartMs!;
    final end = audioEndMs ?? (start + 2500);
    return start <= segEndMs && end >= segStartMs;
  }

  bool hitTest(Offset normalizedTap, {double tolerance = 0.028}) {
    if (points.isEmpty) return false;
    final double effectiveRadius = math.max(tolerance, normalizedWidth * 1.5);

    if (points.length == 1) {
      final pt = Offset(points.first.x, points.first.y);
      return (pt - normalizedTap).distance <= effectiveRadius;
    }

    for (int i = 0; i < points.length - 1; i++) {
      final a = Offset(points[i].x, points[i].y);
      final b = Offset(points[i + 1].x, points[i + 1].y);
      final dist = _distanceToSegment(normalizedTap, a, b);
      if (dist <= effectiveRadius) return true;
    }
    return false;
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final ap = p - a;
    final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lenSq == 0.0) return ap.distance;
    final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / lenSq).clamp(0.0, 1.0);
    final projection = Offset(a.dx + t * ab.dx, a.dy + t * ab.dy);
    return (p - projection).distance;
  }

  /// 필기 이동 도구(DrawingTool.strokeMove)로 드래그할 때 획 전체 좌표를 평행이동
  void translateStroke(double dx, double dy) {
    for (int i = 0; i < points.length; i++) {
      final pt = points[i];
      points[i] = NormalizedPoint(
        x: (pt.x + dx).clamp(0.01, 0.99),
        y: (pt.y + dy).clamp(0.01, 0.99),
        pressure: pt.pressure,
        audioOffsetMs: pt.audioOffsetMs,
      );
    }
  }

  /// [굿노트 스타일 Hold-to-Snap 도형 보정]
  /// 선이나 도형을 그린 뒤 펜 끝을 0.4초간 멈추면 궤적을 분석해
  /// 1) 반듯한 직선(및 수평 밑줄), 2) 반듯한 직사각형 박스, 3) 매끄러운 원·타원으로 자동 보정합니다.
  String? trySnapPointsToCleanShape() {
    if (points.length < 5) return null;

    final Offset first = Offset(points.first.x, points.first.y);
    final Offset last = Offset(points.last.x, points.last.y);
    final double chordLen = (last - first).distance;

    double arcLen = 0.0;
    double minX = first.dx, maxX = first.dx;
    double minY = first.dy, maxY = first.dy;

    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
      if (i > 0) {
        final prev = points[i - 1];
        arcLen += (Offset(p.x, p.y) - Offset(prev.x, prev.y)).distance;
      }
    }

    final int? startStamp = points.first.audioOffsetMs ?? audioStartMs;
    final int? endStamp = points.last.audioOffsetMs ?? audioEndMs;

    // 1) 직선/밑줄 판별: 시점-종점 직선 거리 대비 실제 궤적 길이 비율이 1.22 이하일 때
    if (chordLen >= 0.04 && (arcLen / math.max(0.001, chordLen)) <= 1.22) {
      // 기울기가 완만한 밑줄(|dy| < 0.022)은 완벽한 수평선으로 스냅
      final double snappedEndY =
          (last.dy - first.dy).abs() < 0.022 ? first.dy : last.dy;
      final Offset targetEnd = Offset(last.dx, snappedEndY);

      points.clear();
      const int segments = 12;
      for (int i = 0; i <= segments; i++) {
        final double t = i / segments;
        points.add(
          NormalizedPoint(
            x: first.dx + (targetEnd.dx - first.dx) * t,
            y: first.dy + (targetEnd.dy - first.dy) * t,
            pressure: 0.6,
            audioOffsetMs: startStamp,
          ),
        );
      }
      return (last.dy - first.dy).abs() < 0.022 ? '반듯한 수평 밑줄' : '반듯한 직선';
    }

    // 2) 닫힌 도형(사각형 vs 원·타원) 판별
    final double boxW = maxX - minX;
    final double boxH = maxY - minY;
    if (boxW >= 0.04 &&
        boxH >= 0.03 &&
        (last - first).distance <= math.max(boxW, boxH) * 0.45) {
      // 바운딩 박스 테두리에 가까운지(사각형) 타원 궤적에 가까운지(원/타원) 편차 비교
      final double cx = (minX + maxX) / 2.0;
      final double cy = (minY + maxY) / 2.0;
      final double rx = boxW / 2.0;
      final double ry = boxH / 2.0;

      double rectErrorSum = 0.0;
      double ellipseErrorSum = 0.0;
      for (final p in points) {
        final double distToVertEdge =
            math.min((p.x - minX).abs(), (maxX - p.x).abs());
        final double distToHorizEdge =
            math.min((p.y - minY).abs(), (maxY - p.y).abs());
        rectErrorSum += math.min(distToVertEdge / boxW, distToHorizEdge / boxH);

        final double normDx = (p.x - cx) / math.max(0.001, rx);
        final double normDy = (p.y - cy) / math.max(0.001, ry);
        final double radialDist = math.sqrt(normDx * normDx + normDy * normDy);
        ellipseErrorSum += (radialDist - 1.0).abs();
      }

      final double avgRectErr = rectErrorSum / points.length;
      final double avgEllipseErr = ellipseErrorSum / points.length;

      points.clear();
      if (avgRectErr <= avgEllipseErr * 0.72) {
        // 반듯한 직사각형 박스로 스냅
        final corners = [
          Offset(minX, minY),
          Offset(maxX, minY),
          Offset(maxX, maxY),
          Offset(minX, maxY),
          Offset(minX, minY),
        ];
        for (int c = 0; c < corners.length - 1; c++) {
          for (int step = 0; step < 5; step++) {
            final t = step / 5.0;
            points.add(
              NormalizedPoint(
                x: corners[c].dx + (corners[c + 1].dx - corners[c].dx) * t,
                y: corners[c].dy + (corners[c + 1].dy - corners[c].dy) * t,
                pressure: 0.6,
                audioOffsetMs: startStamp,
              ),
            );
          }
        }
        points.add(
          NormalizedPoint(
            x: minX,
            y: minY,
            pressure: 0.6,
            audioOffsetMs: endStamp,
          ),
        );
        return '반듯한 직사각형 박스';
      } else {
        // 매끄러운 타원/원형으로 스냅
        const int steps = 32;
        for (int i = 0; i <= steps; i++) {
          final double theta = (i / steps) * 2 * math.pi;
          points.add(
            NormalizedPoint(
              x: (cx + rx * math.cos(theta)).clamp(0.01, 0.99),
              y: (cy + ry * math.sin(theta)).clamp(0.01, 0.99),
              pressure: 0.6,
              audioOffsetMs: startStamp,
            ),
          );
        }
        return '매끄러운 원·타원';
      }
    }

    return null;
  }

  Map<String, dynamic> toJson() => {
        'stroke_id': strokeId,
        'tool': tool.name,
        'color': color.toARGB32(),
        'w': normalizedWidth,
        'pts': points.map((pt) => pt.toJson()).toList(),
        if (recordingSessionId != null) 'rec_id': recordingSessionId,
        if (audioStartMs != null) 't_start': audioStartMs,
        if (audioEndMs != null) 't_end': audioEndMs,
      };

  factory NormalizedStroke.fromJson(Map<String, dynamic> json) {
    final toolName = (json['tool'] as String?) ?? 'pen';
    final matchedTool = DrawingTool.values.firstWhere(
      (t) => t.name == toolName,
      orElse: () => DrawingTool.pen,
    );
    return NormalizedStroke(
      strokeId: json['stroke_id'] as String,
      tool: matchedTool,
      color: Color((json['color'] as num).toInt()),
      normalizedWidth: (json['w'] as num).toDouble(),
      points: (json['pts'] as List<dynamic>)
          .map((e) => NormalizedPoint.fromJson(e as Map<String, dynamic>))
          .toList(),
      recordingSessionId: json['rec_id'] as String?,
      audioStartMs: (json['t_start'] as num?)?.toInt(),
      audioEndMs: (json['t_end'] as num?)?.toInt(),
    );
  }
}

/// 강의 음성 녹음 구간별 전사(Transcript) 세그먼트 모델
class AudioTranscriptSegment {
  final int startMs;
  final int endMs;
  final int pageNumber;
  final String transcriptText;
  final String keyConceptTag;

  const AudioTranscriptSegment({
    required this.startMs,
    required this.endMs,
    required this.pageNumber,
    required this.transcriptText,
    this.keyConceptTag = '핵심설명',
  });

  /// 검색 키워드(query)가 전사 원문이나 핵심 개념 태그에 포함되어 있는지 대소문자 구분 없이 검사
  bool matchesKeyword(String query) {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) return true;
    return transcriptText.toLowerCase().contains(trimmed) ||
        keyConceptTag.toLowerCase().contains(trimmed);
  }

  String get formattedStart {
    final sec = (startMs ~/ 1000).clamp(0, 359999);
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get formattedRange {
    final sSec = (startMs ~/ 1000).clamp(0, 359999);
    final eSec = (endMs ~/ 1000).clamp(0, 359999);
    final sm = (sSec ~/ 60).toString().padLeft(2, '0');
    final ss = (sSec % 60).toString().padLeft(2, '0');
    final em = (eSec ~/ 60).toString().padLeft(2, '0');
    final es = (eSec % 60).toString().padLeft(2, '0');
    return '$sm:$ss~$em:$es';
  }

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'endMs': endMs,
        'pageNumber': pageNumber,
        'transcriptText': transcriptText,
        'keyConceptTag': keyConceptTag,
      };

  factory AudioTranscriptSegment.fromJson(Map<String, dynamic> json) {
    return AudioTranscriptSegment(
      startMs: (json['startMs'] as num?)?.toInt() ?? 0,
      endMs: (json['endMs'] as num?)?.toInt() ?? 10000,
      pageNumber: (json['pageNumber'] as num?)?.toInt() ?? 1,
      transcriptText: (json['transcriptText'] as String?) ?? '',
      keyConceptTag: (json['keyConceptTag'] as String?) ?? '핵심설명',
    );
  }
}

/// 키워드 매칭 또는 필기 연동된 음성 구간만 모아 연속 재생하는 오디오북 플레이리스트 트랙 모델.
/// 실제 오디오 파일 재생 시 just_audio의 ClippingAudioSource(start, end) 및
/// ConcatenatingAudioSource(children: ...)로 1:1 매핑됩니다.
class AudiobookPlaylistTrack {
  final String trackId;
  final AudioTranscriptSegment segment;
  final List<NormalizedStroke> linkedStrokes;
  final List<NormalizedMaskRect> linkedMasks;
  final String sourceFilterLabel;

  const AudiobookPlaylistTrack({
    required this.trackId,
    required this.segment,
    required this.linkedStrokes,
    this.linkedMasks = const <NormalizedMaskRect>[],
    required this.sourceFilterLabel,
  });

  int get effectiveStartMs => segment.startMs;

  int get effectiveEndMs => segment.endMs;

  int get durationMs => (effectiveEndMs - effectiveStartMs).clamp(1000, 600000);

  String get formattedClipRange => segment.formattedRange;

  /// 음성 빈칸 퀴즈 모드에서 질문 대상이 되는 첫 번째 미개봉(또는 연동) 암기 가림막
  NormalizedMaskRect? get primaryQuizMask {
    if (linkedMasks.isEmpty) return null;
    for (final m in linkedMasks) {
      if (!m.isRevealed) return m;
    }
    return linkedMasks.first;
  }

  /// 교수님이 핵심 정답(가림막 키워드)을 말씀하시기 직전에 오디오를 일시정지할 목표 시점(ms)
  int? get quizPauseTriggerMs {
    final mask = primaryQuizMask;
    if (mask == null) return null;
    return mask.pauseBeforeAnswerMs(segment);
  }

  /// 음성 빈칸 퀴즈 모드에서 아직 가림막이 열리지 않았을 때 정답 키워드를 마스킹한 전사 자막
  String get clozeMaskedTranscript {
    String masked = segment.transcriptText;
    for (final m in linkedMasks) {
      if (!m.isRevealed && m.hintKeyword.trim().isNotEmpty) {
        masked = masked.replaceAll(
          m.hintKeyword,
          '[ ❓ 빈칸 퀴즈: 가림막 탭하여 정답 확인 ]',
        );
      }
    }
    return masked;
  }

  /// just_audio 패키지의 ClippingAudioSource 생성에 바로 사용할 수 있는 구간 메타데이터
  Map<String, dynamic> toJustAudioClippingDescriptor(String audioFilePath) => {
        'audioFilePath': audioFilePath,
        'clipStartMs': effectiveStartMs,
        'clipEndMs': effectiveEndMs,
        'pageNumber': segment.pageNumber,
        'keyConceptTag': segment.keyConceptTag,
        'linkedStrokeIds': linkedStrokes.map((s) => s.strokeId).toList(),
        'linkedMaskIds': linkedMasks.map((m) => m.maskId).toList(),
      };
}

/// 선택한 오디오북 플레이리스트 구간별 1페이지 핵심 요약 항목
class CheatSheetTrackItem {
  final int trackOrder;
  final int pageNumber;
  final int startMs;
  final int endMs;
  final String timeRange;
  final String keyConcept;
  final String condensedPoint;
  final String clozeBlankKeyword;
  final String strokeNoteSummary;

  const CheatSheetTrackItem({
    required this.trackOrder,
    required this.pageNumber,
    this.startMs = 0,
    this.endMs = 20000,
    required this.timeRange,
    required this.keyConcept,
    required this.condensedPoint,
    required this.clozeBlankKeyword,
    required this.strokeNoteSummary,
  });

  factory CheatSheetTrackItem.fromJson(Map<String, dynamic> json, int order) {
    return CheatSheetTrackItem(
      trackOrder: (json['trackOrder'] as num?)?.toInt() ?? order,
      pageNumber: (json['pageNumber'] as num?)?.toInt() ?? 14,
      startMs: (json['startMs'] as num?)?.toInt() ?? ((order - 1) * 20000),
      endMs: (json['endMs'] as num?)?.toInt() ?? (order * 20000),
      timeRange: (json['timeRange'] as String?) ?? '00:00~00:20',
      keyConcept: (json['keyConcept'] as String?) ?? '핵심 개념',
      condensedPoint: (json['condensedPoint'] as String?) ?? '',
      clozeBlankKeyword: (json['clozeBlankKeyword'] as String?) ?? '',
      strokeNoteSummary: (json['strokeNoteSummary'] as String?) ?? '필기 강조',
    );
  }
}

/// 시험 직전 1페이지 핵심 요약본(1-Page Cheat Sheet) 모델
class OnePagePlaylistCheatSheet {
  final String sheetTitle;
  final String subjectAndTopic;
  final String examDdayLabel;
  final String ultraShortExecutiveTakeaway;
  final List<CheatSheetTrackItem> trackItems;
  final List<String> mustMemorizeChecklist;
  final DateTime generatedAt;

  OnePagePlaylistCheatSheet({
    required this.sheetTitle,
    required this.subjectAndTopic,
    required this.examDdayLabel,
    required this.ultraShortExecutiveTakeaway,
    required this.trackItems,
    required this.mustMemorizeChecklist,
    DateTime? generatedAt,
  }) : generatedAt = generatedAt ?? DateTime.now();

  factory OnePagePlaylistCheatSheet.fromJson(
    Map<String, dynamic> json, {
    required String fallbackSubjectAndTopic,
    required String fallbackExamDdayLabel,
  }) {
    final rawItems = (json['trackItems'] as List<dynamic>?) ?? const [];
    final items = <CheatSheetTrackItem>[];
    for (int i = 0; i < rawItems.length; i++) {
      items.add(
        CheatSheetTrackItem.fromJson(
          rawItems[i] as Map<String, dynamic>,
          i + 1,
        ),
      );
    }
    return OnePagePlaylistCheatSheet(
      sheetTitle:
          (json['sheetTitle'] as String?) ?? '시험 직전 1페이지 핵심 요약본',
      subjectAndTopic:
          (json['subjectAndTopic'] as String?) ?? fallbackSubjectAndTopic,
      examDdayLabel:
          (json['examDdayLabel'] as String?) ?? fallbackExamDdayLabel,
      ultraShortExecutiveTakeaway:
          (json['ultraShortExecutiveTakeaway'] as String?) ?? '',
      trackItems: items,
      mustMemorizeChecklist:
          (json['mustMemorizeChecklist'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              const <String>[],
    );
  }
}

class LectureAudioAnalysisResult {
  final String lectureSummary;
  final List<String> examHighlightPoints;
  final List<AudioTranscriptSegment> segments;

  const LectureAudioAnalysisResult({
    required this.lectureSummary,
    required this.examHighlightPoints,
    required this.segments,
  });

  factory LectureAudioAnalysisResult.fromJson(Map<String, dynamic> json) {
    return LectureAudioAnalysisResult(
      lectureSummary: (json['lectureSummary'] as String?) ?? '',
      examHighlightPoints: (json['examHighlightPoints'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
      segments: (json['segments'] as List<dynamic>?)
              ?.map(
                (e) => AudioTranscriptSegment.fromJson(
                  e as Map<String, dynamic>,
                ),
              )
              .toList() ??
          const <AudioTranscriptSegment>[],
    );
  }
}

class LectureAudioSession {
  final String sessionId;
  final String docId;
  String title;
  Uint8List? audioBytes;
  String audioMimeType;
  int totalDurationMs;
  String aiLectureSummary;
  List<String> examHighlightPoints;
  List<AudioTranscriptSegment> segments;

  LectureAudioSession({
    required this.sessionId,
    required this.docId,
    required this.title,
    this.audioBytes,
    this.audioMimeType = 'audio/mp4',
    required this.totalDurationMs,
    this.aiLectureSummary = '',
    this.examHighlightPoints = const [],
    required this.segments,
  });

  AudioTranscriptSegment? segmentAt(int positionMs) {
    for (final seg in segments) {
      if (positionMs >= seg.startMs && positionMs <= seg.endMs) {
        return seg;
      }
    }
    return segments.isNotEmpty ? segments.last : null;
  }

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'doc_id': docId,
        'title': title,
        'total_duration_ms': totalDurationMs,
        'ai_lecture_summary': aiLectureSummary,
        'exam_highlight_points': examHighlightPoints,
        'segments_json': segments.map((s) => s.toJson()).toList(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
}

/// 가림막(Masking Tape) 위에 애플펜슬·S펜으로 작성한 손글씨 답안에 대한 Gemini 채점 결과 모델
class HandwrittenMaskGradeResult {
  final String recognizedHandwriting;
  final bool isCorrect;
  final int score;
  final String feedback;
  final DateTime gradedAt;

  HandwrittenMaskGradeResult({
    required this.recognizedHandwriting,
    required this.isCorrect,
    required this.score,
    required this.feedback,
    DateTime? gradedAt,
  }) : gradedAt = gradedAt ?? DateTime.now();

  factory HandwrittenMaskGradeResult.fromJson(Map<String, dynamic> json) {
    return HandwrittenMaskGradeResult(
      recognizedHandwriting:
          (json['recognizedHandwriting'] as String?) ?? '',
      isCorrect: (json['isCorrect'] as bool?) ?? false,
      score: (json['score'] as num?)?.toInt() ?? 0,
      feedback: (json['feedback'] as String?) ?? '',
    );
  }
}

/// 에빙하우스 망각곡선 및 SuperMemo SM-2 알고리즘 기반 가림막 복습 스케줄 모델
class EbbinghausReviewSchedule {
  int repetitionCount;
  double easeFactor;
  int intervalDays;
  DateTime nextReviewAt;
  int lastScore;

  EbbinghausReviewSchedule({
    this.repetitionCount = 0,
    this.easeFactor = 2.5,
    this.intervalDays = 0,
    DateTime? nextReviewAt,
    this.lastScore = 0,
  }) : nextReviewAt = nextReviewAt ?? DateTime.now();

  /// 손글씨 채점 점수(0~100점)를 SM-2 품질 등급(0~5)으로 변환해 다음 복습 주기를 계산
  void recordAttemptScore(int score) {
    lastScore = score.clamp(0, 100);
    // 0~100점을 SM-2 quality(0~5)로 매핑
    final int quality = switch (lastScore) {
      >= 95 => 5,
      >= 85 => 4,
      >= 70 => 3,
      >= 50 => 2,
      >= 30 => 1,
      _ => 0,
    };

    if (quality < 3) {
      // 오답 또는 불완전 암기: 복습 횟수 초기화 & 오늘 즉시 재복습
      repetitionCount = 0;
      intervalDays = 0;
      nextReviewAt = DateTime.now().add(const Duration(minutes: 15));
    } else {
      if (repetitionCount == 0) {
        intervalDays = 1;
      } else if (repetitionCount == 1) {
        intervalDays = 3;
      } else {
        intervalDays = (intervalDays * easeFactor).round().clamp(4, 30);
      }
      repetitionCount++;
      nextReviewAt = DateTime.now().add(Duration(days: intervalDays));
    }

    easeFactor = (easeFactor +
            (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02)))
        .clamp(1.3, 3.0);
  }

  bool get isDueNow =>
      intervalDays == 0 || !nextReviewAt.isAfter(DateTime.now());

  String get badgeLabel {
    if (repetitionCount == 0 && lastScore == 0) {
      return '미학습 (오늘 첫 복습 권장)';
    }
    if (intervalDays == 0) {
      return '🚨 즉시 재시험 필요 (${lastScore}점)';
    }
    return '복습 주기 ${intervalDays}일 · EF ${easeFactor.toStringAsFixed(1)} (${lastScore}점)';
  }

  Map<String, dynamic> toJson() => {
        'rep': repetitionCount,
        'ef': double.parse(easeFactor.toStringAsFixed(2)),
        'ivl': intervalDays,
        'next': nextReviewAt.toUtc().toIso8601String(),
        'score': lastScore,
      };

  factory EbbinghausReviewSchedule.fromJson(Map<String, dynamic>? json) {
    if (json == null) return EbbinghausReviewSchedule();
    return EbbinghausReviewSchedule(
      repetitionCount: (json['rep'] as num?)?.toInt() ?? 0,
      easeFactor: (json['ef'] as num?)?.toDouble() ?? 2.5,
      intervalDays: (json['ivl'] as num?)?.toInt() ?? 0,
      nextReviewAt: json['next'] != null
          ? DateTime.tryParse(json['next'] as String) ?? DateTime.now()
          : DateTime.now(),
      lastScore: (json['score'] as num?)?.toInt() ?? 0,
    );
  }
}

class NormalizedMaskRect {
  final String maskId;
  final int pageNumber;
  final Rect normalizedRect;
  final String hintKeyword;
  final int? answerRevealAudioMs;
  bool isRevealed;

  /// 가림막 로컬 영역(0.0~1.0) 위에 애플펜슬/S펜으로 직접 쓴 손글씨 답안 획 목록
  final List<List<Offset>> handwrittenInkStrokes;
  HandwrittenMaskGradeResult? lastGradeResult;
  bool isGradingInProgress;
  final EbbinghausReviewSchedule reviewSchedule;

  NormalizedMaskRect({
    required this.maskId,
    required this.pageNumber,
    required this.normalizedRect,
    required this.hintKeyword,
    this.answerRevealAudioMs,
    this.isRevealed = false,
    List<List<Offset>>? handwrittenInkStrokes,
    this.lastGradeResult,
    this.isGradingInProgress = false,
    EbbinghausReviewSchedule? reviewSchedule,
  })  : handwrittenInkStrokes = handwrittenInkStrokes ?? <List<Offset>>[],
        reviewSchedule = reviewSchedule ?? EbbinghausReviewSchedule();

  bool get hasHandwrittenInk =>
      handwrittenInkStrokes.any((stroke) => stroke.length > 1);

  void clearHandwriting() {
    handwrittenInkStrokes.clear();
    lastGradeResult = null;
  }

  /// 가림막 위에 작성된 손글씨 획들을 오프스크린 Canvas(PictureRecorder)로 렌더링하여
  /// Gemini 멀티모달 Vision API에 전달할 PNG 바이트(Uint8List)로 변환합니다.
  Future<Uint8List?> renderHandwritingToPngBytes({
    int widthPx = 440,
    int heightPx = 140,
  }) async {
    if (!hasHandwrittenInk) return null;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, widthPx.toDouble(), heightPx.toDouble()),
      );

      // 흰색 답안지 배경 렌더링
      final bgPaint = Paint()..color = Colors.white;
      canvas.drawRect(
        Rect.fromLTWH(0, 0, widthPx.toDouble(), heightPx.toDouble()),
        bgPaint,
      );

      // 손글씨 펜 획 렌더링 (인식률을 높이는 고대비 진청색 잉크)
      final inkPaint = Paint()
        ..color = const Color(0xFF0D47A1)
        ..strokeWidth = 3.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      for (final stroke in handwrittenInkStrokes) {
        if (stroke.length < 2) continue;
        final path = Path()
          ..moveTo(
            stroke.first.dx * widthPx,
            stroke.first.dy * heightPx,
          );
        for (int i = 1; i < stroke.length; i++) {
          path.lineTo(
            stroke[i].dx * widthPx,
            stroke[i].dy * heightPx,
          );
        }
        canvas.drawPath(path, inkPaint);
      }

      final picture = recorder.endRecording();
      final image = await picture.toImage(widthPx, heightPx);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('가림막 손글씨 PNG 렌더링 오류: $e');
      return null;
    }
  }

  /// 해당 가림막이 특정 오디오 전사 세그먼트의 빈칸 퀴즈 대상인지 판별
  bool matchesTranscriptSegment(AudioTranscriptSegment seg) {
    if (pageNumber != seg.pageNumber) return false;
    if (answerRevealAudioMs != null &&
        answerRevealAudioMs! >= seg.startMs &&
        answerRevealAudioMs! <= seg.endMs) {
      return true;
    }
    final cleanHint = hintKeyword.trim();
    if (cleanHint.isEmpty) return false;
    return seg.matchesKeyword(cleanHint) ||
        cleanHint.toLowerCase().contains(seg.keyConceptTag.toLowerCase());
  }

  /// 교수님이 정답 키워드를 발화하기 직전(약 0.6초 전)에 오디오를 멈출 시점(ms) 계산
  int pauseBeforeAnswerMs(AudioTranscriptSegment seg) {
    if (answerRevealAudioMs != null &&
        answerRevealAudioMs! >= seg.startMs &&
        answerRevealAudioMs! <= seg.endMs) {
      return (answerRevealAudioMs! - 600).clamp(seg.startMs + 800, seg.endMs - 500);
    }
    // 텍스트 내 정답 키워드 등장 비율로 발화 직전 시점 추정
    final idx = seg.transcriptText
        .toLowerCase()
        .indexOf(hintKeyword.trim().toLowerCase());
    if (idx > 0 && seg.transcriptText.isNotEmpty) {
      final ratio = (idx / seg.transcriptText.length).clamp(0.25, 0.78);
      return seg.startMs + ((seg.endMs - seg.startMs) * ratio).round();
    }
    return seg.startMs + ((seg.endMs - seg.startMs) * 0.45).round();
  }

  Rect toPixelRect(Size pageSize) => Rect.fromLTWH(
        normalizedRect.left * pageSize.width,
        normalizedRect.top * pageSize.height,
        normalizedRect.width * pageSize.width,
        normalizedRect.height * pageSize.height,
      );

  Map<String, dynamic> toJson() => {
        'mask_id': maskId,
        'page': pageNumber,
        'rect': {
          'x': double.parse(normalizedRect.left.toStringAsFixed(4)),
          'y': double.parse(normalizedRect.top.toStringAsFixed(4)),
          'w': double.parse(normalizedRect.width.toStringAsFixed(4)),
          'h': double.parse(normalizedRect.height.toStringAsFixed(4)),
        },
        'hint': hintKeyword,
        'rev': isRevealed,
        'srs': reviewSchedule.toJson(),
      };

  factory NormalizedMaskRect.fromJson(Map<String, dynamic> json) {
    final r = json['rect'] as Map<String, dynamic>;
    return NormalizedMaskRect(
      maskId: json['mask_id'] as String,
      pageNumber: (json['page'] as num?)?.toInt() ?? 1,
      normalizedRect: Rect.fromLTWH(
        (r['x'] as num).toDouble(),
        (r['y'] as num).toDouble(),
        (r['w'] as num).toDouble(),
        (r['h'] as num).toDouble(),
      ),
      hintKeyword: (json['hint'] as String?) ?? '암기 영역',
      isRevealed: (json['rev'] as bool?) ?? false,
      reviewSchedule: EbbinghausReviewSchedule.fromJson(
        json['srs'] as Map<String, dynamic>?,
      ),
    );
  }
}

class WrongAnswerStudyCard {
  final String cardId;
  final String docId;
  final int pageNumber;
  final Rect normalizedCropRect;
  final Uint8List? croppedImageBytes;
  final String recognizedQuestion;
  final String stepByStepSolution;
  final String twinQuestion;
  final String twinAnswer;
  bool isTwinAnswerRevealed;

  WrongAnswerStudyCard({
    required this.cardId,
    required this.docId,
    required this.pageNumber,
    required this.normalizedCropRect,
    this.croppedImageBytes,
    required this.recognizedQuestion,
    required this.stepByStepSolution,
    required this.twinQuestion,
    required this.twinAnswer,
    this.isTwinAnswerRevealed = false,
  });

  Map<String, dynamic> toJson() => {
        'card_id': cardId,
        'doc_id': docId,
        'page_number': pageNumber,
        'crop_rect': {
          'x': double.parse(normalizedCropRect.left.toStringAsFixed(4)),
          'y': double.parse(normalizedCropRect.top.toStringAsFixed(4)),
          'w': double.parse(normalizedCropRect.width.toStringAsFixed(4)),
          'h': double.parse(normalizedCropRect.height.toStringAsFixed(4)),
        },
        'recognized_question': recognizedQuestion,
        'step_by_step_solution': stepByStepSolution,
        'twin_question': twinQuestion,
        'twin_answer': twinAnswer,
        'is_twin_revealed': isTwinAnswerRevealed,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  factory WrongAnswerStudyCard.fromJson(Map<String, dynamic> json) {
    final r = (json['crop_rect'] as Map<String, dynamic>?) ??
        const {'x': 0.1, 'y': 0.1, 'w': 0.5, 'h': 0.2};
    return WrongAnswerStudyCard(
      cardId: (json['card_id'] as String?) ?? 'card_default',
      docId: (json['doc_id'] as String?) ?? 'doc_default',
      pageNumber: (json['page_number'] as num?)?.toInt() ?? 1,
      normalizedCropRect: Rect.fromLTWH(
        (r['x'] as num).toDouble(),
        (r['y'] as num).toDouble(),
        (r['w'] as num).toDouble(),
        (r['h'] as num).toDouble(),
      ),
      recognizedQuestion: (json['recognized_question'] as String?) ?? '',
      stepByStepSolution: (json['step_by_step_solution'] as String?) ?? '',
      twinQuestion: (json['twin_question'] as String?) ?? '',
      twinAnswer: (json['twin_answer'] as String?) ?? '',
      isTwinAnswerRevealed: (json['is_twin_revealed'] as bool?) ?? false,
    );
  }
}

/// 강의 녹음 중 촬영한 칠판 판서·실험 사진 스티커 노트 모델
/// PDF 페이지 여백의 정규화 좌표(normalizedPosition)에 부착되며 녹음 시점(audioTimestampMs)과 연동됩니다.
class BoardPhotoStickerNote {
  final String stickerId;
  final int pageNumber;
  Offset normalizedPosition;
  final Uint8List? photoBytes;
  final String aiExtractedSummary;
  final int audioTimestampMs;
  bool isExpanded;

  BoardPhotoStickerNote({
    required this.stickerId,
    required this.pageNumber,
    required this.normalizedPosition,
    this.photoBytes,
    required this.aiExtractedSummary,
    required this.audioTimestampMs,
    this.isExpanded = true,
  });

  String get formattedTimestamp {
    final sec = (audioTimestampMs ~/ 1000).clamp(0, 359999);
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// [핵심 4] 듀얼 PDF 나란히 보기에서 주 문서(기출문제) 페이지와 보조 문서(강의교안) 페이지를 잇는 양방향 핀 모델
class CrossDocumentPinLink {
  final String pinId;
  final int primaryPageNumber;
  final int secondaryPageNumber;
  final String relationSummary;

  const CrossDocumentPinLink({
    required this.pinId,
    required this.primaryPageNumber,
    required this.secondaryPageNumber,
    required this.relationSummary,
  });
}

/// [핵심 5] 흘려 쓴 손필기·수식을 정돈된 인쇄체 텍스트·수식·비교표 박스로 변환할 때의 표시 스타일
enum CleanBlockStyle {
  typesetSummary,
  mathChemFormula,
  comparisonTable,
}

/// [핵심 5] 손필기 획(NormalizedStroke)들을 Gemini Vision으로 인식해 정돈된 인쇄체·수식·표로 변환한 스티커 모델
class CleanTypesetBlockSticker {
  final String blockId;
  final int pageNumber;
  Offset normalizedPosition;
  CleanBlockStyle activeStyle;
  final String headerTitle;
  final String cleanSummaryText;
  final String cleanFormulaLatex;
  final List<List<String>> comparisonTableRows;
  final List<NormalizedStroke> archivedOriginalStrokes;

  CleanTypesetBlockSticker({
    required this.blockId,
    required this.pageNumber,
    required this.normalizedPosition,
    this.activeStyle = CleanBlockStyle.comparisonTable,
    required this.headerTitle,
    required this.cleanSummaryText,
    required this.cleanFormulaLatex,
    required this.comparisonTableRows,
    this.archivedOriginalStrokes = const <NormalizedStroke>[],
  });
}

/// 라이브 스터디룸(Co-Study)에 접속한 스터디원(다른 태블릿)의 실시간 펜슬 레이저 포인터 및 상태 모델
class CoStudyPeerCursor {
  final String peerId;
  final String peerName;
  final String deviceLabel;
  final int activePage;
  Offset normalizedPointer;
  final Color cursorColor;

  CoStudyPeerCursor({
    required this.peerId,
    required this.peerName,
    required this.deviceLabel,
    required this.activePage,
    required this.normalizedPointer,
    required this.cursorColor,
  });
}

/// 화학 구조식·생물 모식도·기출 메커니즘을 단계별 인과관계 그래프로 변환한 마인드맵 노드·엣지 모델
class ConceptMindMapNode {
  final String nodeId;
  final String title;
  final String subtitle;
  final Offset normalizedCenter;
  final Color accentColor;

  const ConceptMindMapNode({
    required this.nodeId,
    required this.title,
    required this.subtitle,
    required this.normalizedCenter,
    required this.accentColor,
  });
}

class ConceptMindMapEdge {
  final String fromNodeId;
  final String toNodeId;
  final String mechanismLabel;

  const ConceptMindMapEdge({
    required this.fromNodeId,
    required this.toNodeId,
    required this.mechanismLabel,
  });
}

/// 과목별 시험 D-Day, 목표 회독 대비 남은 페이지 수, 미암기 가림막(SM-2) 입력 데이터 모델
class SubjectExamQuotaInput {
  final String subjectName;
  final String docTitle;
  final int dDayRemaining;
  final int totalPages;
  final int currentPage;
  final int currentReadCount;
  final int targetReadCount;
  final int unmasteredMaskCount;
  final int wrongAnswerCardCount;

  const SubjectExamQuotaInput({
    required this.subjectName,
    required this.docTitle,
    required this.dDayRemaining,
    required this.totalPages,
    required this.currentPage,
    required this.currentReadCount,
    required this.targetReadCount,
    required this.unmasteredMaskCount,
    required this.wrongAnswerCardCount,
  });

  /// 목표 회독(targetReadCount) 완주까지 남은 총 페이지 수 계산
  int get totalRemainingPagesForTargetReads {
    final int currentPassRemaining =
        (totalPages - currentPage).clamp(0, totalPages);
    final int futurePassesRemaining =
        (targetReadCount - currentReadCount).clamp(0, 10) * totalPages;
    return math.max(4, currentPassRemaining + futurePassesRemaining);
  }

  /// 시험 D-Day 전까지 매일 읽어야 하는 최소 권장 페이지 수
  int get baseDailyRequiredPages =>
      (totalRemainingPagesForTargetReads / math.max(1, dDayRemaining)).ceil();

  /// 오늘 우선 정복해야 할 미암기 가림막 수 (D-Day가 임박할수록 가중)
  int get baseDailyRequiredMasks => unmasteredMaskCount == 0
      ? 0
      : (unmasteredMaskCount / math.max(1, math.min(dDayRemaining, 3))).ceil();

  /// 과목별 긴급도 가중치 (D-Day 역수 + 미암기 가림막 + 오답 카드 + 남은 페이지 반영)
  double get urgencyWeight =>
      (120.0 / math.max(1, dDayRemaining)) +
      (unmasteredMaskCount * 6.0) +
      (wrongAnswerCardCount * 4.0) +
      (baseDailyRequiredPages * 1.5);
}

/// AI 스터디 플래너가 계산한 과목별 오늘의 학습 할당량 항목
class DailySubjectStudyTask {
  final String subjectName;
  final String docTitle;
  final int dDayRemaining;
  final int todayPageQuota;
  final int startPage;
  final int endPage;
  final int todayMaskQuota;
  final int allocatedMinutes;
  final int recommendedPomodoroSessions;
  final String aiStrategyTip;
  bool isCompletedToday;

  DailySubjectStudyTask({
    required this.subjectName,
    required this.docTitle,
    required this.dDayRemaining,
    required this.todayPageQuota,
    required this.startPage,
    required this.endPage,
    required this.todayMaskQuota,
    required this.allocatedMinutes,
    required this.recommendedPomodoroSessions,
    required this.aiStrategyTip,
    this.isCompletedToday = false,
  });

  String get dDayBadge =>
      dDayRemaining <= 0 ? 'D-Day' : 'D-$dDayRemaining';

  String get pageRangeLabel => 'p.$startPage ~ p.$endPage (${todayPageQuota}p)';
}

/// AI 일일 학습 할당량 플래너 전체 결과 모델
class AiStudyQuotaPlanResult {
  final int availableDailyMinutes;
  final String aiCoachHeadline;
  final List<DailySubjectStudyTask> tasks;

  const AiStudyQuotaPlanResult({
    required this.availableDailyMinutes,
    required this.aiCoachHeadline,
    required this.tasks,
  });
}

/// AI 스터디 플래너의 과목별 할당량을 실제 시작·종료 시각이 지정된 25분 뽀모도로 + 휴식 블록으로 변환한 모델
class ScheduledPomodoroTimeBlock {
  final int notificationId;
  final int blockOrder;
  final String subjectName;
  final String docTitle;
  final String dDayBadge;
  final int startPage;
  final String pageRangeLabel;
  final int targetMaskCount;
  final int sessionIndexInSubject;
  final int totalSessionsInSubject;
  final DateTime startTime;
  final DateTime endTime;
  final int breakMinutesAfter;

  const ScheduledPomodoroTimeBlock({
    required this.notificationId,
    required this.blockOrder,
    required this.subjectName,
    required this.docTitle,
    required this.dDayBadge,
    required this.startPage,
    required this.pageRangeLabel,
    required this.targetMaskCount,
    required this.sessionIndexInSubject,
    required this.totalSessionsInSubject,
    required this.startTime,
    required this.endTime,
    required this.breakMinutesAfter,
  });

  String _twoDigits(int n) => n.toString().padLeft(2, '0');

  String get formattedTimeWindow =>
      '${_twoDigits(startTime.hour)}:${_twoDigits(startTime.minute)} ~ ${_twoDigits(endTime.hour)}:${_twoDigits(endTime.minute)}';

  String get notificationTitle =>
      '⏰ [뽀모도로 #$blockOrder] $subjectName ($dDayBadge) 학습 시작!';

  String get notificationBody =>
      '$pageRangeLabel 진도 (${sessionIndexInSubject}/${totalSessionsInSubject}세션) · 미암기 가림막 $targetMaskCount개 손글씨 인출 후 ${breakMinutesAfter}분 휴식';

  Map<String, dynamic> toNotificationJson() => {
        'id': notificationId,
        'title': notificationTitle,
        'body': notificationBody,
        'scheduledAtIso': startTime.toUtc().toIso8601String(),
        'payload': jsonEncode({
          'subjectName': subjectName,
          'startPage': startPage,
          'blockOrder': blockOrder,
        }),
      };
}

/// 플렉슬(Flexcil) 스타일 플로팅 단권화 서브노트에 스크랩된 원본 PDF 발췌 조각 모델
/// 탭하면 원본 PDF의 [sourcePageNumber] 및 [linkedAudioMs] 녹음 시점으로 즉시 역추적합니다.
class SubNoteScrapClip {
  final String clipId;
  final int sourcePageNumber;
  final Rect sourceNormalizedRect;
  final Uint8List? croppedImageBytes;
  final String extractedSnippetText;
  String userAnnotationMemo;
  final int? linkedAudioMs;

  SubNoteScrapClip({
    required this.clipId,
    required this.sourcePageNumber,
    required this.sourceNormalizedRect,
    this.croppedImageBytes,
    required this.extractedSnippetText,
    required this.userAnnotationMemo,
    this.linkedAudioMs,
  });

  String get formattedAudioBadge {
    if (linkedAudioMs == null) return '';
    final sec = (linkedAudioMs! ~/ 1000).clamp(0, 359999);
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class PageAnnotationSnapshot {
  final String docId;
  final int pageNumber;
  final List<NormalizedStroke> strokes;
  final List<NormalizedMaskRect> masks;
  final Set<String> deletedIds;

  PageAnnotationSnapshot({
    required this.docId,
    required this.pageNumber,
    required this.strokes,
    required this.masks,
    Set<String>? deletedIds,
  }) : deletedIds = deletedIds ?? <String>{};

  PageAnnotationSnapshot mergeWith(PageAnnotationSnapshot remote) {
    final combinedDeleted = <String>{...deletedIds, ...remote.deletedIds};

    final strokeMap = <String, NormalizedStroke>{};
    for (final s in strokes) {
      if (!combinedDeleted.contains(s.strokeId)) {
        strokeMap[s.strokeId] = s;
      }
    }
    for (final s in remote.strokes) {
      if (!combinedDeleted.contains(s.strokeId)) {
        strokeMap[s.strokeId] = s;
      }
    }

    final maskMap = <String, NormalizedMaskRect>{};
    for (final m in masks) {
      if (!combinedDeleted.contains(m.maskId)) {
        maskMap[m.maskId] = m;
      }
    }
    for (final m in remote.masks) {
      if (!combinedDeleted.contains(m.maskId)) {
        maskMap[m.maskId] = m;
      }
    }

    return PageAnnotationSnapshot(
      docId: docId,
      pageNumber: pageNumber,
      strokes: strokeMap.values.toList(),
      masks: maskMap.values.toList(),
      deletedIds: combinedDeleted,
    );
  }
}

class AutoFolderItem {
  final String id;
  final String subjectName;
  final String subTopicSummary;
  final String docTypeBadge;
  final List<String> keywords;
  int docCount;

  AutoFolderItem({
    required this.id,
    required this.subjectName,
    required this.subTopicSummary,
    required this.docTypeBadge,
    required this.keywords,
    this.docCount = 1,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'subject_name': subjectName,
        'sub_topic_summary': subTopicSummary,
        'doc_type_badge': docTypeBadge,
        'keywords': keywords,
        'doc_count': docCount,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  factory AutoFolderItem.fromJson(Map<String, dynamic> json) {
    final rawKeywords = json['keywords'];
    List<String> parsedKeywords = const [];
    if (rawKeywords is List) {
      parsedKeywords = rawKeywords.map((e) => e.toString()).toList();
    } else if (rawKeywords is String && rawKeywords.isNotEmpty) {
      parsedKeywords =
          (jsonDecode(rawKeywords) as List).map((e) => e.toString()).toList();
    }
    return AutoFolderItem(
      id: (json['id'] as String?) ?? 'folder_default',
      subjectName: (json['subject_name'] as String?) ?? '미분류',
      subTopicSummary: (json['sub_topic_summary'] as String?) ?? '',
      docTypeBadge: (json['doc_type_badge'] as String?) ?? '강의교안',
      keywords: parsedKeywords,
      docCount: (json['doc_count'] as num?)?.toInt() ?? 1,
    );
  }
}

class DocumentClassificationResult {
  final String subjectFolder;
  final String subTopic;
  final String docType;
  final List<String> keywords;
  final String summary;
  final String? extractedExamDate;
  final int importanceScore;

  const DocumentClassificationResult({
    required this.subjectFolder,
    required this.subTopic,
    required this.docType,
    required this.keywords,
    required this.summary,
    this.extractedExamDate,
    required this.importanceScore,
  });

  factory DocumentClassificationResult.fromJson(Map<String, dynamic> json) {
    return DocumentClassificationResult(
      subjectFolder: (json['subjectFolder'] as String?) ?? '미분류 과목',
      subTopic: (json['subTopic'] as String?) ?? '일반 단원',
      docType: (json['docType'] as String?) ?? '강의교안',
      keywords: (json['keywords'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
      summary: (json['summary'] as String?) ?? '',
      extractedExamDate: json['extractedExamDate'] as String?,
      importanceScore: (json['importanceScore'] as num?)?.toInt() ?? 3,
    );
  }
}

class NotebookQaAnswer {
  final String question;
  final String answer;
  final List<int> citedPages;

  const NotebookQaAnswer({
    required this.question,
    required this.answer,
    required this.citedPages,
  });

  factory NotebookQaAnswer.fromJson(
    String question,
    Map<String, dynamic> json,
  ) {
    return NotebookQaAnswer(
      question: question,
      answer: (json['answer'] as String?) ?? '',
      citedPages: (json['citedPages'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const <int>[],
    );
  }
}

class TabletLayoutPolicy {
  final double width;
  final double height;
  final bool isExamFocusMode;
  final bool isLeftHanded;

  const TabletLayoutPolicy({
    required this.width,
    required this.height,
    required this.isExamFocusMode,
    required this.isLeftHanded,
  });

  double get aspectRatio => height > 0 ? width / height : 1.33;

  bool get showPersistentFolderPane =>
      !isExamFocusMode && aspectRatio >= 1.48 && width >= 1100;

  int get folderFlex => showPersistentFolderPane ? 18 : 0;

  int get canvasFlex {
    if (isExamFocusMode) return 75;
    if (showPersistentFolderPane) return 54;
    return 68;
  }

  int get sidebarFlex {
    if (isExamFocusMode) return 25;
    if (showPersistentFolderPane) return 28;
    return 32;
  }

  String get layoutBadgeLabel {
    if (isExamFocusMode) return '시험 집중 2단 (75:25)';
    if (showPersistentFolderPane) return '16:10 와이드 3단 (18:54:28)';
    return '4:3 표준 2단 (68:32)';
  }
}

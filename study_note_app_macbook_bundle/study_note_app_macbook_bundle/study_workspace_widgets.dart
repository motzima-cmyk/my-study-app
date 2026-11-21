import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show PointerDeviceKind, FontFeature;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart'
    show kPrimaryStylusButton, kSecondaryStylusButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf_pdf;
import 'package:syncfusion_flutter_pdfviewer/syncfusion_flutter_pdfviewer.dart';

import 'study_models.dart';
import 'study_services.dart';
import 'study_sync_repository.dart';

/// ============================================================================
/// [Widgets Module] 반응형 2·3단 태블릿 워크스페이스 UI · 듀얼 PDF · 서브노트 · CustomPainter 모음
/// 파일 경로: lib/widgets/study_workspace_widgets.dart (또는 lib/study_workspace_widgets.dart)
/// ============================================================================

/// 다크 모드 / 라이트 모드 실시간 전환을 위한 전역 테마 상태 노티파이어
final ValueNotifier<ThemeMode> studyAppThemeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.light);

typedef AdaptiveStudyNoteApp = StudyNoteApp;

class StudyNoteApp extends StatelessWidget {
  const StudyNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: studyAppThemeModeNotifier,
      builder: (context, currentThemeMode, _) {
        return MaterialApp(
          title: 'AI Study Note Workspace',
          debugShowCheckedModeBanner: false,
          themeMode: currentThemeMode,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF2575FC),
              brightness: Brightness.light,
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF9DD2FF),
              brightness: Brightness.dark,
            ),
          ),
          home: const AdaptiveStudyWorkspace(),
        );
      },
    );
  }
}


class AdaptiveStudyWorkspace extends StatefulWidget {
  const AdaptiveStudyWorkspace({super.key});

  @override
  State<AdaptiveStudyWorkspace> createState() => _AdaptiveStudyWorkspaceState();
}

class _AdaptiveStudyWorkspaceState extends State<AdaptiveStudyWorkspace>
    with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _pdfPageBoundaryKey = GlobalKey();
  late final TabController _sidebarTabController =
      TabController(length: 2, vsync: this);

  final GeminiStudyService _geminiService = GeminiStudyService();
  final PdfFlattenExportService _exportService = PdfFlattenExportService();
  final StudyScheduleNotificationAndCalendarService
      _scheduleCalendarService =
      StudyScheduleNotificationAndCalendarService();
  final List<ScheduledPomodoroTimeBlock> _scheduledPomodoroBlocks =
      <ScheduledPomodoroTimeBlock>[];
  late final StudySyncRepository _syncRepo = StudySyncRepository(
    deviceId: 'tablet_${DateTime.now().millisecondsSinceEpoch % 10000}',
  );

  final PdfViewerController _pdfViewerController = PdfViewerController();
  Uint8List? _loadedPdfBytes;
  String _currentDocId = 'doc_bio_chap3';
  String _currentFileName = '3장 세포호흡_기출.pdf';
  String _currentSubjectFolder = '생물학개론';
  String _currentSubTopic = '3장 세포호흡';
  String _currentDocType = '기출문제';
  String _currentAiSummary =
      '진핵세포의 전자전달계와 산화적 인산화 기출문제를 다룬 핵심 자료입니다.';
  bool _isClassifyingPdf = false;
  bool _isExportingPdf = false;
  bool _isAskingNotebook = false;
  bool _isAnalyzingLasso = false;
  bool _isTranscribingAudio = false;
  SyncState _syncState = SyncState.synced;

  bool _isRecordingAudio = false;
  bool _isPlayingAudio = false;
  bool _enableAudioReplayFilter = true;
  int _currentAudioPositionMs = 12000;

  /// 전사 대본 키워드 검색 또는 오디오 재생 시 동시에 하이라이트되는 필기 획 ID 집합
  final Set<String> _highlightedStrokeIds = <String>{};
  String _activeTranscriptSearchQuery = '';
  Timer? _audioClockTimer;

  /// 키워드 하이라이트 오디오북 플레이리스트 상태
  final List<AudiobookPlaylistTrack> _audiobookPlaylist =
      <AudiobookPlaylistTrack>[];
  int _currentPlaylistTrackIndex = 0;
  bool _isPlaylistModeActive = false;
  bool _playlistLoopEnabled = true;
  double _playbackSpeed = 1.0;
  String _playlistTitle = '전체 핵심 구간 오디오북';

  /// 가림막(Masking Tape) + 오디오북 결합 '음성 빈칸 퀴즈 모드' 상태
  bool _isVoiceClozeQuizMode = false;
  NormalizedMaskRect? _activeQuizPausedMask;
  final Set<String> _quizTriggeredTrackIds = <String>{};
  int _voiceQuizSolvedCount = 0;

  /// 선택된 오디오북 플레이리스트 기반 '시험 직전 1페이지 핵심 요약본' 상태
  bool _isGeneratingCheatSheet = false;
  OnePagePlaylistCheatSheet? _latestOnePageCheatSheet;

  /// 아이패드 애플펜슬·갤럭시 S펜 '손글씨 빈칸 채점 모드' 활성화 상태
  bool _isHandwritingGradingMode = true;

  /// 태블릿 화면 비율 & iPad Split View 멀티태스킹 실시간 프리뷰 시뮬레이터 프리셋
  /// ('auto' | 'ipad_4_3' | 'android_16_10' | 'split_50_50')
  String _simulatedViewportPreset = 'auto';

  /// 애플펜슬 더블탭(UIPencilInteraction) 및 갤럭시 S펜 에어액션(MethodChannel / Stylus Button) 연동
  static const MethodChannel _stylusHardwareChannel =
      MethodChannel('com.studynote.stylus/pencil_interactions');
  DrawingTool _previousDrawingTool = DrawingTool.highlighter;

  /// 페이지별 칠판 판서 사진 스티커 노트 목록
  late final Map<int, List<BoardPhotoStickerNote>> _boardStickersByPage = {
    14: [
      BoardPhotoStickerNote(
        stickerId: 'sticker_bio_board_1',
        pageNumber: 14,
        normalizedPosition: const Offset(0.66, 0.14),
        aiExtractedSummary:
            '[칠판 판서 AI 요약] 복합체 I·III·IV 양성자(H+) 펌핑 방향: 기질(pH 8.0) → 막 사이 공간(pH 7.0)',
        audioTimestampMs: 28000,
        isExpanded: true,
      ),
    ],
  };

  List<BoardPhotoStickerNote> get _currentPageBoardStickers =>
      _boardStickersByPage.putIfAbsent(
          _currentPage, () => <BoardPhotoStickerNote>[]);

  /// [TOP 1] 굿노트 스타일 자동 도형·직선 보정(Hold-to-Snap) 및 필기 이동(strokeMove) 상태
  bool _enableHoldToSnapShape = true;
  Timer? _shapeSnapHoldTimer;
  NormalizedStroke? _movingTargetStroke;
  Offset? _lastMovePointerNormalized;

  /// [TOP 2] 플렉슬(Flexcil) 스타일 플로팅 단권화 서브노트 팝업 & 드래그 스크랩 상태
  bool _isFloatingSubNoteOpen = false;
  Offset _floatingSubNotePosition = const Offset(36, 72);
  SubNoteTemplate _subNoteTemplate = SubNoteTemplate.cornell;
  final List<List<Offset>> _subNoteFreehandStrokes = <List<Offset>>[];
  late final List<SubNoteScrapClip> _subNoteScrapClips = <SubNoteScrapClip>[
    SubNoteScrapClip(
      clipId: 'clip_p8_etc',
      sourcePageNumber: 8,
      sourceNormalizedRect: const Rect.fromLTWH(0.10, 0.20, 0.80, 0.25),
      extractedSnippetText:
          '[p.8 교안 발췌] 복합체 I, III, IV를 거치며 막 사이 공간으로 양성자(H+)가 능동 수송된다.',
      userAnnotationMemo: '★ 복합체 II(숙신산 탈수소효소)는 H+를 펌핑하지 않음 주의!',
      linkedAudioMs: 12000,
    ),
    SubNoteScrapClip(
      clipId: 'clip_p14_atp',
      sourcePageNumber: 14,
      sourceNormalizedRect: const Rect.fromLTWH(0.08, 0.35, 0.84, 0.28),
      extractedSnippetText:
          '[p.14 기출 14번 발췌] 진핵세포 전자전달계 위치 = 미토콘드리아 내막 / 구동력 = 수소 이온 농도 기울기(ΔpH)',
      userAnnotationMemo: '원핵생물(세균)은 세포막에서 진행됨 (빈출 비교 보기)',
      linkedAudioMs: 28000,
    ),
  ];

  /// [TOP 3] 페이지 썸네일 그리드 필터링(북마크·필기·가림막) 및 중간 삽입된 빈 노트 페이지 상태
  final Set<int> _bookmarkedPages = <int>{8, 14};
  final Map<int, SubNoteTemplate> _insertedNotePages =
      <int, SubNoteTemplate>{};

  /// [핵심 4] 듀얼 PDF 나란히 보기 (강의교안 PDF + 기출문제 PDF 동시 열람 & 양방향 교차 핀) 상태
  bool _isDualPdfSplitView = false;
  final PdfViewerController _secondaryPdfController = PdfViewerController();
  Uint8List? _secondaryPdfBytes;
  String _secondaryFileName = '생물학개론_3장_강의교안.pdf';
  int _secondaryCurrentPage = 8;
  int _secondaryTotalPages = 32;
  late final List<CrossDocumentPinLink> _crossDocPins = <CrossDocumentPinLink>[
    const CrossDocumentPinLink(
      pinId: 'pin_p14_p8',
      primaryPageNumber: 14,
      secondaryPageNumber: 8,
      relationSummary: '기출 p.14 (문항 14) ↔ 교안 p.8 (미토콘드리아 내막 모식도)',
    ),
    const CrossDocumentPinLink(
      pinId: 'pin_p14_p11',
      primaryPageNumber: 14,
      secondaryPageNumber: 11,
      relationSummary: '기출 p.14 (구동력 빈칸) ↔ 교안 p.11 (ΔpH 화학삼투 공식)',
    ),
  ];

  /// [핵심 5] 흘려 쓴 손필기 → 깔끔한 인쇄체·수식·표 정돈 박스 상태
  bool _isConvertingHandwriting = false;
  final Map<int, List<CleanTypesetBlockSticker>> _cleanTypesetBlocksByPage =
      <int, List<CleanTypesetBlockSticker>>{};

  List<CleanTypesetBlockSticker> get _currentPageCleanBlocks =>
      _cleanTypesetBlocksByPage.putIfAbsent(
        _currentPage,
        () => <CleanTypesetBlockSticker>[],
      );

  /// 라이브 스터디룸(Co-Study) 실시간 협동 필기 & 피어 레이저 커서 상태
  bool _isCoStudyRoomActive = false;
  Timer? _coStudyPeerSimTimer;
  double _peerAnimPhase = 0.0;
  final List<CoStudyPeerCursor> _coStudyPeers = [
    CoStudyPeerCursor(
      peerId: 'peer_ipad_minsu',
      peerName: '김민수',
      deviceLabel: 'iPad Pro 13 (4:3)',
      activePage: 14,
      normalizedPointer: const Offset(0.38, 0.42),
      cursorColor: const Color(0xFF00897B),
    ),
    CoStudyPeerCursor(
      peerId: 'peer_tab_jihyun',
      peerName: '박지현',
      deviceLabel: 'Galaxy Tab S9 (16:10)',
      activePage: 14,
      normalizedPointer: const Offset(0.52, 0.60),
      cursorColor: const Color(0xFF8E24AA),
    ),
  ];

  late final LectureAudioSession _lectureAudioSession = LectureAudioSession(
    sessionId: 'rec_bio_chap3_01',
    docId: 'doc_bio_chap3',
    title: '생물학개론 3장 세포호흡 교수님 강조 포인트 녹음',
    totalDurationMs: 60000,
    aiLectureSummary:
        '교수님은 진핵세포 산화적 인산화의 장소(미토콘드리아 내막)와 ATP 합성의 직접적인 구동력(수소 이온 농도 기울기 ΔpH) 두 가지를 핵심 출제 포인트로 강조하셨습니다.',
    examHighlightPoints: const [
      '전자전달계 복합체(I~IV) 및 ATP 합성효소의 위치 = 미토콘드리아 내막',
      '화학삼투적 인산화의 직접적 구동력 = 수소 이온 농도 기울기(ΔpH)',
    ],
    segments: [
      const AudioTranscriptSegment(
        startMs: 0,
        endMs: 19999,
        pageNumber: 14,
        keyConceptTag: '산화적 인산화 출제빈도',
        transcriptText:
            '[00:12 교수님 음성] "자, 문항 14번 제목에 별표 치세요. 산화적 인산화는 매 시험마다 무조건 출제되는 핵심 파트입니다."',
      ),
      const AudioTranscriptSegment(
        startMs: 20000,
        endMs: 39999,
        pageNumber: 14,
        keyConceptTag: '미토콘드리아 내막',
        transcriptText:
            '[00:28 교수님 음성] "1번 빈칸 밑줄 그으세요! 진핵세포의 전자전달계 복합체 I~IV와 ATP 합성효소는 반드시 미토콘드리아 내막(크리스테)에 존재합니다."',
      ),
      const AudioTranscriptSegment(
        startMs: 40000,
        endMs: 60000,
        pageNumber: 14,
        keyConceptTag: '수소 이온 농도 기울기(ΔpH)',
        transcriptText:
            '[00:45 교수님 음성] "2번 구동력에도 형광펜 칠해 두세요. 막 사이 공간으로 펌핑된 수소 이온 농도 기울기(ΔpH)가 ATP 합성의 직접적 원동력입니다."',
      ),
    ],
  );

  final Map<int, String> _extractedPageTexts = {
    8: '강의교안 8페이지: 미토콘드리아 내막의 전자전달계 복합체 I, II, III, IV를 거쳐 전자가 산소로 전달되며 막 사이 공간으로 양성자(H+)가 펌핑된다.',
    14: '기출문제 14페이지: 진핵세포에서 산화적 인산화가 일어나는 장소는 미토콘드리아 내막이며, 수소 이온 농도 기울기(ΔpH)가 ATP 합성의 직접적인 구동력이다.',
  };

  bool _isLeftHanded = false;
  bool _isExamFocusMode = false;
  bool _stylusOnlyMode = true;

  DrawingTool _selectedTool = DrawingTool.pen;
  int _currentPage = 14;
  int _totalPages = 42;
  int _readCount = 2;
  final int _targetReadCount = 3;
  String _examDdayLabel = '중간고사 D-12';

  int _remainingSeconds = 24 * 60 + 15;
  bool _isTimerRunning = false;
  Timer? _pomodoroTimer;

  final List<AutoFolderItem> _folders = [
    AutoFolderItem(
      id: 'folder_bio',
      subjectName: '생물학개론',
      subTopicSummary: '3장 세포호흡 (문서 4개)',
      docTypeBadge: '기출·교안',
      keywords: ['미토콘드리아', '산화적 인산화', 'ATP'],
      docCount: 4,
    ),
    AutoFolderItem(
      id: 'folder_chem',
      subjectName: '유기화학 I',
      subTopicSummary: '입체화학 요약본 (문서 7개)',
      docTypeBadge: '요약노트',
      keywords: ['카이랄성', '거울상이성질체'],
      docCount: 7,
    ),
    AutoFolderItem(
      id: 'folder_schedule',
      subjectName: '학사 및 시험 일정표',
      subTopicSummary: '시험일 2건 자동 추출됨',
      docTypeBadge: '일정연동',
      keywords: ['중간고사', '기말고사'],
      docCount: 2,
    ),
  ];

  late final Map<int, List<NormalizedStroke>> _strokesByPage = {
    14: [
      NormalizedStroke(
        strokeId: 's_audio_12s',
        tool: DrawingTool.highlighter,
        color: const Color(0x66FFEE58),
        normalizedWidth: 0.022,
        recordingSessionId: 'rec_bio_chap3_01',
        audioStartMs: 12000,
        audioEndMs: 14500,
        points: const [
          NormalizedPoint(x: 0.08, y: 0.21, audioOffsetMs: 12000),
          NormalizedPoint(x: 0.30, y: 0.21, audioOffsetMs: 12800),
          NormalizedPoint(x: 0.55, y: 0.21, audioOffsetMs: 13600),
          NormalizedPoint(x: 0.82, y: 0.21, audioOffsetMs: 14500),
        ],
      ),
      NormalizedStroke(
        strokeId: 's_audio_28s',
        tool: DrawingTool.pen,
        color: const Color(0xFF1565C0),
        normalizedWidth: 0.004,
        recordingSessionId: 'rec_bio_chap3_01',
        audioStartMs: 28000,
        audioEndMs: 31000,
        points: const [
          NormalizedPoint(x: 0.08, y: 0.39, audioOffsetMs: 28000),
          NormalizedPoint(x: 0.25, y: 0.39, audioOffsetMs: 29000),
          NormalizedPoint(x: 0.44, y: 0.39, audioOffsetMs: 30000),
          NormalizedPoint(x: 0.62, y: 0.39, audioOffsetMs: 31000),
        ],
      ),
      NormalizedStroke(
        strokeId: 's_audio_45s',
        tool: DrawingTool.highlighter,
        color: const Color(0x6680CBC4),
        normalizedWidth: 0.022,
        recordingSessionId: 'rec_bio_chap3_01',
        audioStartMs: 45000,
        audioEndMs: 48000,
        points: const [
          NormalizedPoint(x: 0.08, y: 0.57, audioOffsetMs: 45000),
          NormalizedPoint(x: 0.28, y: 0.57, audioOffsetMs: 46000),
          NormalizedPoint(x: 0.48, y: 0.57, audioOffsetMs: 47000),
          NormalizedPoint(x: 0.68, y: 0.57, audioOffsetMs: 48000),
        ],
      ),
    ],
  };

  final Map<int, Set<String>> _deletedIdsByPage = {};
  NormalizedStroke? _activeStroke;
  Offset? _maskDragStartNormalized;
  Offset? _maskDragCurrentNormalized;
  Offset? _lassoDragStartNormalized;
  Offset? _lassoDragCurrentNormalized;

  late final Map<int, List<NormalizedMaskRect>> _masksByPage = {
    14: [
      NormalizedMaskRect(
        maskId: 'm_201',
        pageNumber: 14,
        normalizedRect: const Rect.fromLTWH(0.28, 0.44, 0.24, 0.055),
        hintKeyword: '미토콘드리아 내막',
        answerRevealAudioMs: 28500,
        isRevealed: false,
      ),
      NormalizedMaskRect(
        maskId: 'm_202',
        pageNumber: 14,
        normalizedRect: const Rect.fromLTWH(0.22, 0.62, 0.20, 0.055),
        hintKeyword: '수소 이온 농도 기울기(ΔpH)',
        answerRevealAudioMs: 45500,
        isRevealed: false,
      ),
    ],
  };

  final List<WrongAnswerStudyCard> _studyCards = [
    WrongAnswerStudyCard(
      cardId: 'card_sample_1',
      docId: 'doc_bio_chap3',
      pageNumber: 14,
      normalizedCropRect: const Rect.fromLTWH(0.08, 0.35, 0.84, 0.22),
      recognizedQuestion: '[p.14 기출 14번] 진핵세포 산화적 인산화 전자전달계의 정확한 위치',
      stepByStepSolution:
          '전자전달계 복합체(I~IV)와 ATP 합성효소는 미토콘드리아 외막이나 기질이 아닌 내막(크리스테)에 존재합니다.',
      twinQuestion:
          '[유사 변형] 세균(원핵생물)에서 산화적 인산화에 관여하는 전자전달계 효소들은 세포의 어느 구조에 존재하는가?',
      twinAnswer: '정답: 원핵생물은 미토콘드리아가 없으므로 세포막(원형질막) 내벽에 존재합니다.',
      isTwinAnswerRevealed: false,
    ),
  ];

  final TextEditingController _questionController = TextEditingController();
  final List<NotebookQaAnswer> _notebookQaHistory = [
    const NotebookQaAnswer(
      question: '산화적 인산화에서 기출 빈도가 가장 높은 핵심 키워드 2개만 뽑아줘.',
      answer:
          '1. 전자전달계와 ATP 합성효소의 위치인 미토콘드리아 내막\n2. 막을 경계로 형성되는 수소 이온 농도 기울기(ΔpH)입니다.',
      citedPages: [14, 8],
    ),
  ];

  List<NormalizedStroke> get _currentPageStrokes =>
      _strokesByPage.putIfAbsent(_currentPage, () => <NormalizedStroke>[]);

  List<NormalizedMaskRect> get _currentPageMasks =>
      _masksByPage.putIfAbsent(_currentPage, () => <NormalizedMaskRect>[]);

  Set<String> get _currentPageDeletedIds =>
      _deletedIdsByPage.putIfAbsent(_currentPage, () => <String>{});

  @override
  void initState() {
    super.initState();
    _initSyncEngine();
    _initStylusHardwareChannel();
  }

  /// iPadOS UIPencilInteraction.didTap 및 Android S-Pen Air Action 네이티브 이벤트 수신
  void _initStylusHardwareChannel() {
    _stylusHardwareChannel.setMethodCallHandler((call) async {
      if (call.method == 'onApplePencilDoubleTap' ||
          call.method == 'onSPenButtonClicked') {
        _handleHardwareStylusQuickSwitch(
          sourceLabel: call.method == 'onApplePencilDoubleTap'
              ? 'Apple Pencil 더블탭'
              : 'Galaxy S펜 버튼',
        );
      }
    });
  }

  /// 애플펜슬 더블탭 또는 S펜 배럴 버튼 클릭 시 현재 도구와 이전 도구(펜 <-> 형광펜/가림막)를 즉시 스왑
  void _handleHardwareStylusQuickSwitch({String sourceLabel = '펜슬 단축키'}) {
    setState(() {
      final current = _selectedTool;
      final nextTool = _previousDrawingTool == current
          ? (current == DrawingTool.pen
              ? DrawingTool.highlighter
              : DrawingTool.pen)
          : _previousDrawingTool;
      _previousDrawingTool = current;
      _selectedTool = nextTool;
    });

    final toolKoreanName = switch (_selectedTool) {
      DrawingTool.pen => '볼펜',
      DrawingTool.highlighter => '형광펜',
      DrawingTool.strokeMove => '필기 선택·이동',
      DrawingTool.maskingTape => '암기 가림막',
      DrawingTool.aiLasso => 'AI 올가미',
      DrawingTool.audioSeek => '오디오 점프',
      DrawingTool.panScroll => '페이지 이동',
    };

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✏️ [$sourceLabel] 도구 즉시 전환 → $toolKoreanName'),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 칠판 판서 사진을 불러오거나 시뮬레이션 이미지를 생성해 현재 PDF 페이지 여백에 스티커 노트로 부착
  Future<void> _insertChalkboardPhotoSticker() async {
    Uint8List? pickedImageBytes;
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg'],
        withData: true,
      );
      if (res != null && res.files.isNotEmpty) {
        pickedImageBytes = res.files.single.bytes;
      }
    } catch (_) {}

    final int stampMs = _currentAudioPositionMs;
    final newSticker = BoardPhotoStickerNote(
      stickerId: 'sticker_${DateTime.now().millisecondsSinceEpoch}',
      pageNumber: _currentPage,
      normalizedPosition: const Offset(0.64, 0.24),
      photoBytes: pickedImageBytes,
      aiExtractedSummary:
          '[칠판 판서 AI 인식] 전자전달계 ΔpH = 1.0 차이 시 ATP 합성효소 회전수 증가 (녹음 ${_formatMs(stampMs)} 연동)',
      audioTimestampMs: stampMs,
      isExpanded: true,
    );

    setState(() {
      _currentPageBoardStickers.add(newSticker);
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '📷 칠판 판서 스티커 노트가 p.$_currentPage 여백에 추가되고 녹음 시점([${newSticker.formattedTimestamp}])과 연결되었습니다.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 라이브 스터디룸(Co-Study) 모드 토글:
  /// Supabase Realtime Broadcast 채널로 스터디원 간 펜슬 레이저 커서와 필기를 실시간 공유합니다.
  void _toggleCoStudyRoom(bool enabled) {
    setState(() {
      _isCoStudyRoomActive = enabled;
    });
    _coStudyPeerSimTimer?.cancel();

    if (enabled) {
      _coStudyPeerSimTimer =
          Timer.periodic(const Duration(milliseconds: 120), (t) {
        if (!mounted || !_isCoStudyRoomActive) {
          t.cancel();
          return;
        }
        setState(() {
          _peerAnimPhase += 0.14;
          _coStudyPeers[0].normalizedPointer = Offset(
            (0.36 + 0.12 * math.cos(_peerAnimPhase)).clamp(0.1, 0.85),
            (0.41 + 0.04 * math.sin(_peerAnimPhase * 1.5)).clamp(0.15, 0.85),
          );
          _coStudyPeers[1].normalizedPointer = Offset(
            (0.48 + 0.14 * math.sin(_peerAnimPhase * 0.8)).clamp(0.1, 0.85),
            (0.59 + 0.03 * math.cos(_peerAnimPhase * 1.3)).clamp(0.15, 0.85),
          );
        });
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '👥 라이브 스터디룸 연결됨: 김민수(iPad Pro) · 박지현(Galaxy Tab S9) 님의 실시간 펜슬 포인터가 캔버스에 표시됩니다.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// 화학 구조식·생물 모식도·기출 메커니즘을 단계별 화살표와 인과관계 노드로 시각화하는 마인드맵 모달
  void _showMechanismMindMapModal() {
    const nodes = <ConceptMindMapNode>[
      ConceptMindMapNode(
        nodeId: 'n1',
        title: '1. NADH · FADH₂ 산화',
        subtitle: '고에너지 전자(2e⁻) 방출',
        normalizedCenter: Offset(0.15, 0.30),
        accentColor: Color(0xFF1565C0),
      ),
      ConceptMindMapNode(
        nodeId: 'n2',
        title: '2. 미토콘드리아 내막 전자전달계',
        subtitle: '복합체 I → III → IV (크리스테)',
        normalizedCenter: Offset(0.50, 0.30),
        accentColor: Color(0xFF00897B),
      ),
      ConceptMindMapNode(
        nodeId: 'n3',
        title: '3. 양성자(H⁺) 능동 수송 & ΔpH 형성',
        subtitle: '기질(pH 8) → 막 사이 공간(pH 7)',
        normalizedCenter: Offset(0.84, 0.30),
        accentColor: Color(0xFFD81B60),
      ),
      ConceptMindMapNode(
        nodeId: 'n4',
        title: '4. ATP 합성효소 (화학삼투적 인산화)',
        subtitle: 'H⁺ 농도 기울기(ΔpH)로 ADP + Pi → ATP',
        normalizedCenter: Offset(0.50, 0.76),
        accentColor: Color(0xFFF57C00),
      ),
      ConceptMindMapNode(
        nodeId: 'n5',
        title: '5. 언커플러(DNP) 예외 기출 포인트',
        subtitle: 'ΔpH 소실 → ATP 합성↓ · 산소 소비 및 열 발생↑',
        normalizedCenter: Offset(0.84, 0.76),
        accentColor: Color(0xFF6A1B9A),
      ),
    ];

    const edges = <ConceptMindMapEdge>[
      ConceptMindMapEdge(
        fromNodeId: 'n1',
        toNodeId: 'n2',
        mechanismLabel: '전자 전달 (e⁻)',
      ),
      ConceptMindMapEdge(
        fromNodeId: 'n2',
        toNodeId: 'n3',
        mechanismLabel: 'H⁺ 펌핑',
      ),
      ConceptMindMapEdge(
        fromNodeId: 'n3',
        toNodeId: 'n4',
        mechanismLabel: '전기화학적 구동력(ΔpH)',
      ),
      ConceptMindMapEdge(
        fromNodeId: 'n3',
        toNodeId: 'n5',
        mechanismLabel: '내막 투과성 증가 시',
      ),
    ];

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.account_tree_outlined,
                  color: colorScheme.primary, size: 22),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Gemini 단계별 메커니즘 화살표 & 개념 마인드맵',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 680,
            height: 340,
            child: Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: CustomPaint(
                painter: ConceptMechanismMindMapPainter(
                  nodes: nodes,
                  edges: edges,
                  textColor: colorScheme.onSurface,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('닫기'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                setState(() {
                  _currentPageBoardStickers.add(
                    BoardPhotoStickerNote(
                      stickerId:
                          'mindmap_${DateTime.now().millisecondsSinceEpoch}',
                      pageNumber: _currentPage,
                      normalizedPosition: const Offset(0.62, 0.32),
                      aiExtractedSummary:
                          '[메커니즘 마인드맵] NADH 산화 → 내막 복합체 I·III·IV → H+ 펌핑(ΔpH) → ATP 합성효소 구동',
                      audioTimestampMs: _currentAudioPositionMs,
                      isExpanded: true,
                    ),
                  );
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '🧠 단계별 메커니즘 마인드맵 요약이 p.$_currentPage 스티커 노트로 부착되었습니다.',
                    ),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.push_pin_outlined, size: 16),
              label: const Text('현재 페이지에 마인드맵 스티커 부착'),
            ),
          ],
        );
      },
    );
  }

  /// 현재 페이지의 선택/핵심 영역을 캡처해 플로팅 단권화 서브노트에 출처 링크와 함께 즉시 스크랩
  Future<void> _scrapCurrentPageHighlightToSubNote() async {
    const defaultScrapRect = Rect.fromLTWH(0.06, 0.18, 0.88, 0.32);
    final Uint8List? cropped =
        await _captureAndCropNormalizedRect(defaultScrapRect);
    final String snippet = _extractedPageTexts[_currentPage] ??
        'p.$_currentPage 핵심 개념 및 기출 지문 발췌 ($_currentSubjectFolder > $_currentSubTopic)';

    setState(() {
      _isFloatingSubNoteOpen = true;
      _subNoteScrapClips.insert(
        0,
        SubNoteScrapClip(
          clipId: 'scrap_${DateTime.now().millisecondsSinceEpoch}',
          sourcePageNumber: _currentPage,
          sourceNormalizedRect: defaultScrapRect,
          croppedImageBytes: cropped,
          extractedSnippetText: snippet,
          userAnnotationMemo:
              'p.$_currentPage 발췌 메모 (탭하면 원본 페이지 및 녹음 시점으로 즉시 이동)',
          linkedAudioMs: _currentAudioPositionMs,
        ),
      );
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '📒 p.$_currentPage 영역이 플로팅 단권화 서브노트에 스크랩되었습니다 (원본 페이지·오디오 양방향 링크 연결됨).',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// [핵심 4] 듀얼 PDF 나란히 보기용 보조 참조 문서(강의교안 PDF) 불러오기
  Future<void> _pickSecondaryReferencePdf() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final file = res.files.single;
      if (file.bytes == null) return;

      int pageCount = 32;
      try {
        final doc = sf_pdf.PdfDocument(inputBytes: file.bytes!);
        pageCount = doc.pages.count;
        doc.dispose();
      } catch (_) {}

      setState(() {
        _isDualPdfSplitView = true;
        _secondaryPdfBytes = file.bytes;
        _secondaryFileName = file.name;
        _secondaryCurrentPage = 1;
        _secondaryTotalPages = pageCount;
      });
    } catch (e) {
      debugPrint('보조 참조 PDF 열기 오류: $e');
    }
  }

  /// [핵심 4] 현재 좌측 문서 페이지(_currentPage)와 우측 보조 문서 페이지(_secondaryCurrentPage)를 양방향 핀으로 연결
  void _createCrossDocumentPin() {
    final newPin = CrossDocumentPinLink(
      pinId: 'pin_${DateTime.now().millisecondsSinceEpoch}',
      primaryPageNumber: _currentPage,
      secondaryPageNumber: _secondaryCurrentPage,
      relationSummary:
          '기출 p.$_currentPage ↔ 교안 p.$_secondaryCurrentPage ($_currentSubTopic 핵심 대조)',
    );
    setState(() {
      _crossDocPins.insert(0, newPin);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '📌 양방향 교차 핀 생성 완료: [주 문서 p.$_currentPage ↔ 참조 교안 p.$_secondaryCurrentPage]',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// [핵심 4] 교차 문서 핀(CrossDocumentPinLink)을 탭했을 때 좌·우 두 PDF 뷰어의 페이지를 동시에 점프
  void _jumpToCrossDocumentPin(CrossDocumentPinLink pin) {
    final targetPrimary = pin.primaryPageNumber.clamp(1, _totalPages);
    final targetSecondary =
        pin.secondaryPageNumber.clamp(1, _secondaryTotalPages);

    setState(() {
      _isDualPdfSplitView = true;
      _currentPage = targetPrimary;
      _secondaryCurrentPage = targetSecondary;
    });

    if (_loadedPdfBytes != null) {
      _pdfViewerController.jumpToPage(targetPrimary);
    }
    if (_secondaryPdfBytes != null) {
      _secondaryPdfController.jumpToPage(targetSecondary);
    }
    _loadAndMergeCurrentPageFromRepo();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '🔗 교차 핀 동기화 이동: 좌측 p.$targetPrimary ↔ 우측 교안 p.$targetSecondary',
        ),
        duration: const Duration(milliseconds: 1800),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// [핵심 5] 현재 페이지의 흘려 쓴 손필기 획(NormalizedStroke)들을 Gemini로 분석해
  /// 깔끔한 인쇄체 요약 · 수식 · 비교표 정돈 박스로 변환하여 페이지 위에 부착합니다.
  Future<void> _convertCurrentPageStrokesToCleanTypesetBlock() async {
    if (_isConvertingHandwriting) return;

    setState(() => _isConvertingHandwriting = true);

    final Uint8List? pageSnapshotBytes = await _captureAndCropNormalizedRect(
      const Rect.fromLTWH(0.05, 0.15, 0.90, 0.55),
    );
    final String pageContext = _extractedPageTexts[_currentPage] ??
        '생물학개론 제3장 세포호흡과 산화적 인산화 ($_currentPage페이지)';

    final CleanTypesetBlockSticker cleanBlock =
        await _geminiService.convertHandwritingStrokesToCleanBlock(
      pageNumber: _currentPage,
      strokesPngBytes: pageSnapshotBytes,
      pageTextContext: pageContext,
      originalStrokes: List<NormalizedStroke>.from(_currentPageStrokes),
    );

    if (!mounted) return;
    setState(() {
      _isConvertingHandwriting = false;
      _currentPageCleanBlocks.add(cleanBlock);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '✨ 손필기 → 인쇄체·수식·표 정돈 완료! p.$_currentPage 하단 블록에서 [비교표 / 수식 / 인쇄체] 탭을 전환해 보세요.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// [TOP 3] 현재 페이지(_currentPage) 바로 뒤에 빈 노트 페이지(코넬노트/줄노트/모눈노트) 삽입
  Future<void> _insertCustomNotePageAfterCurrent(
    SubNoteTemplate template,
  ) async {
    final int insertPageNum = _currentPage + 1;

    // 1) insertPageNum 이상인 기존 페이지의 필기, 가림막, 스티커, 북마크 번호를 +1씩 시프트
    Map<int, List<T>> shiftPageMap<T>(Map<int, List<T>> source) {
      final next = <int, List<T>>{};
      source.forEach((page, items) {
        next[page >= insertPageNum ? page + 1 : page] = items;
      });
      return next;
    }

    final shiftedStrokes = shiftPageMap(_strokesByPage);
    final shiftedMasks = shiftPageMap(_masksByPage);
    final shiftedStickers = shiftPageMap(_boardStickersByPage);

    final nextInsertedTemplates = <int, SubNoteTemplate>{};
    _insertedNotePages.forEach((p, t) {
      nextInsertedTemplates[p >= insertPageNum ? p + 1 : p] = t;
    });
    nextInsertedTemplates[insertPageNum] = template;

    final nextBookmarks = <int>{};
    for (final p in _bookmarkedPages) {
      nextBookmarks.add(p >= insertPageNum ? p + 1 : p);
    }

    // 2) 실제 PDF 바이트가 로드되어 있으면 Syncfusion PdfDocument에 새 페이지를 삽입하고 노트 양식 선을 그림
    Uint8List? updatedPdfBytes = _loadedPdfBytes;
    if (_loadedPdfBytes != null) {
      try {
        final doc = sf_pdf.PdfDocument(inputBytes: _loadedPdfBytes!);
        final int insertIdx =
            (_currentPage).clamp(0, doc.pages.count);
        final sf_pdf.PdfPage newPage = doc.pages.insert(insertIdx);
        final Size sz = newPage.getClientSize();
        final g = newPage.graphics;
        final linePen =
            sf_pdf.PdfPen(sf_pdf.PdfColor(200, 215, 235), width: 0.7);

        if (template == SubNoteTemplate.cornell) {
          g.drawLine(
            sf_pdf.PdfPen(sf_pdf.PdfColor(21, 101, 192), width: 1.2),
            Offset(24, 58),
            Offset(sz.width - 24, 58),
          );
          g.drawLine(
            sf_pdf.PdfPen(sf_pdf.PdfColor(21, 101, 192), width: 1.2),
            Offset(sz.width * 0.30, 58),
            Offset(sz.width * 0.30, sz.height - 110),
          );
          g.drawLine(
            sf_pdf.PdfPen(sf_pdf.PdfColor(21, 101, 192), width: 1.2),
            Offset(24, sz.height - 110),
            Offset(sz.width - 24, sz.height - 110),
          );
        }
        for (double y = 80; y < sz.height - 40; y += 22) {
          g.drawLine(linePen, Offset(24, y), Offset(sz.width - 24, y));
        }
        if (template == SubNoteTemplate.grid) {
          for (double x = 24; x < sz.width - 24; x += 22) {
            g.drawLine(linePen, Offset(x, 60), Offset(x, sz.height - 40));
          }
        }
        final saved = await doc.save();
        doc.dispose();
        updatedPdfBytes = Uint8List.fromList(saved);
      } catch (e) {
        debugPrint('PDF 중간 페이지 삽입 폴백: $e');
      }
    }

    setState(() {
      _strokesByPage
        ..clear()
        ..addAll(shiftedStrokes);
      _masksByPage
        ..clear()
        ..addAll(shiftedMasks);
      _boardStickersByPage
        ..clear()
        ..addAll(shiftedStickers);
      _insertedNotePages
        ..clear()
        ..addAll(nextInsertedTemplates);
      _bookmarkedPages
        ..clear()
        ..addAll(nextBookmarks);
      _totalPages += 1;
      _currentPage = insertPageNum;
      _loadedPdfBytes = updatedPdfBytes;
    });

    if (_loadedPdfBytes != null) {
      _pdfViewerController.jumpToPage(insertPageNum);
    }

    final templateLabel = switch (template) {
      SubNoteTemplate.cornell => '코넬노트(Cornell)',
      SubNoteTemplate.ruled => '줄노트(Ruled)',
      SubNoteTemplate.grid => '모눈종이(Grid)',
    };

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '📄 p.$insertPageNum 위치에 [$templateLabel] 풀이 여백 페이지가 삽입되었습니다 (전체 $_totalPages페이지).',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// [TOP 3] 전체 PDF 페이지 중 필기·가림막·북마크가 있는 페이지만 필터링해 모아보는 썸네일 그리드 & 페이지 삽입 모달
  void _showPageThumbnailGridAndInsertModal() {
    String selectedFilter = 'all'; // 'all' | 'strokes' | 'masks' | 'bookmarks' | 'inserted'

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setGridState) {
            final colorScheme = Theme.of(ctx).colorScheme;
            final allPageNumbers =
                List<int>.generate(_totalPages, (i) => i + 1);

            final filteredPages = allPageNumbers.where((pNum) {
              final hasStrokes =
                  (_strokesByPage[pNum]?.isNotEmpty ?? false);
              final hasMasks = (_masksByPage[pNum]?.isNotEmpty ?? false);
              final isBookmarked = _bookmarkedPages.contains(pNum);
              final isInserted = _insertedNotePages.containsKey(pNum);

              return switch (selectedFilter) {
                'strokes' => hasStrokes,
                'masks' => hasMasks,
                'bookmarks' => isBookmarked,
                'inserted' => isInserted,
                _ => true,
              };
            }).toList();

            final strokePageCount = allPageNumbers
                .where((p) => _strokesByPage[p]?.isNotEmpty ?? false)
                .length;
            final maskPageCount = allPageNumbers
                .where((p) => _masksByPage[p]?.isNotEmpty ?? false)
                .length;

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.80,
              maxChildSize: 0.94,
              builder: (ctx, scrollController) {
                return Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.grid_view_rounded,
                            color: colorScheme.primary,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '페이지 썸네일 그리드 필터 & 중간 여백 노트 페이지 삽입',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  '총 $_totalPages페이지 · 필기 페이지 ${strokePageCount}p · 가림막 페이지 ${maskPageCount}p · 별표 북마크 ${_bookmarkedPages.length}p',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Wrap(
                            spacing: 6,
                            children: [
                              FilledButton.tonalIcon(
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  _insertCustomNotePageAfterCurrent(
                                    SubNoteTemplate.cornell,
                                  );
                                },
                                icon: const Icon(Icons.note_add_outlined,
                                    size: 15),
                                label: Text(
                                  'p.$_currentPage 뒤에 코넬노트 삽입',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  _insertCustomNotePageAfterCurrent(
                                    SubNoteTemplate.ruled,
                                  );
                                },
                                icon: const Icon(Icons.format_align_justify,
                                    size: 15),
                                label: const Text(
                                  '+ 줄노트 삽입',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  _insertCustomNotePageAfterCurrent(
                                    SubNoteTemplate.grid,
                                  );
                                },
                                icon: const Icon(Icons.grid_on, size: 15),
                                label: const Text(
                                  '+ 모눈노트 삽입',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 필터 칩 바
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          ChoiceChip(
                            label: Text(
                              '전체 페이지 ($_totalPages)',
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: selectedFilter == 'all',
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) =>
                                setGridState(() => selectedFilter = 'all'),
                          ),
                          ChoiceChip(
                            avatar: const Icon(Icons.edit, size: 14),
                            label: Text(
                              '필기 있는 페이지만 ($strokePageCount)',
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: selectedFilter == 'strokes',
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => setGridState(
                                () => selectedFilter = 'strokes'),
                          ),
                          ChoiceChip(
                            avatar: const Icon(
                                Icons.visibility_off_outlined,
                                size: 14),
                            label: Text(
                              '암기 가림막 페이지 ($maskPageCount)',
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: selectedFilter == 'masks',
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) =>
                                setGridState(() => selectedFilter = 'masks'),
                          ),
                          ChoiceChip(
                            avatar: const Icon(Icons.star, size: 14),
                            label: Text(
                              '별표 북마크 페이지 (${_bookmarkedPages.length})',
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: selectedFilter == 'bookmarks',
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => setGridState(
                                () => selectedFilter = 'bookmarks'),
                          ),
                          if (_insertedNotePages.isNotEmpty)
                            ChoiceChip(
                              avatar: const Icon(
                                  Icons.note_alt_outlined,
                                  size: 14),
                              label: Text(
                                '삽입된 여백 노트 (${_insertedNotePages.length})',
                                style: const TextStyle(fontSize: 11),
                              ),
                              selected: selectedFilter == 'inserted',
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) => setGridState(
                                  () => selectedFilter = 'inserted'),
                            ),
                        ],
                      ),
                      const Divider(height: 20),

                      // 썸네일 바둑판 그리드
                      Expanded(
                        child: filteredPages.isEmpty
                            ? Center(
                                child: Text(
                                  '선택한 필터 조건에 해당하는 페이지가 없습니다.',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                            : GridView.builder(
                                controller: scrollController,
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 170,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  childAspectRatio: 0.74,
                                ),
                                itemCount: filteredPages.length,
                                itemBuilder: (ctx, idx) {
                                  final pNum = filteredPages[idx];
                                  final isCurrent = pNum == _currentPage;
                                  final sCount =
                                      _strokesByPage[pNum]?.length ?? 0;
                                  final mCount =
                                      _masksByPage[pNum]?.length ?? 0;
                                  final isStarred =
                                      _bookmarkedPages.contains(pNum);
                                  final noteTpl = _insertedNotePages[pNum];

                                  return InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () {
                                      Navigator.of(ctx).pop();
                                      _jumpToCitedPage(pNum);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: isCurrent
                                            ? colorScheme.primaryContainer
                                                .withValues(alpha: 0.45)
                                            : colorScheme.surfaceContainerLow,
                                        borderRadius:
                                            BorderRadius.circular(12),
                                        border: Border.all(
                                          color: isCurrent
                                              ? colorScheme.primary
                                              : colorScheme.outlineVariant,
                                          width: isCurrent ? 2.2 : 1.0,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment
                                                    .spaceBetween,
                                            children: [
                                              Container(
                                                padding: const EdgeInsets
                                                    .symmetric(
                                                  horizontal: 7,
                                                  vertical: 2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: isCurrent
                                                      ? colorScheme.primary
                                                      : colorScheme
                                                          .surfaceContainerHighest,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          6),
                                                ),
                                                child: Text(
                                                  'p.$pNum',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight:
                                                        FontWeight.bold,
                                                    color: isCurrent
                                                        ? colorScheme
                                                            .onPrimary
                                                        : colorScheme
                                                            .onSurface,
                                                  ),
                                                ),
                                              ),
                                              InkWell(
                                                onTap: () {
                                                  setState(() {
                                                    if (isStarred) {
                                                      _bookmarkedPages
                                                          .remove(pNum);
                                                    } else {
                                                      _bookmarkedPages
                                                          .add(pNum);
                                                    }
                                                  });
                                                  setGridState(() {});
                                                },
                                                child: Icon(
                                                  isStarred
                                                      ? Icons.star
                                                      : Icons.star_border,
                                                  size: 18,
                                                  color: isStarred
                                                      ? const Color(
                                                          0xFFF59E0B)
                                                      : colorScheme
                                                          .onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Expanded(
                                            child: Container(
                                              width: double.infinity,
                                              padding:
                                                  const EdgeInsets.all(6),
                                              decoration: BoxDecoration(
                                                color: noteTpl != null
                                                    ? const Color(0xFFFFFDE7)
                                                    : Colors.white,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: Colors.grey.shade300,
                                                ),
                                              ),
                                              child: Text(
                                                noteTpl != null
                                                    ? '[삽입된 ${noteTpl.name.toUpperCase()} 풀이 노트 페이지]'
                                                    : (_extractedPageTexts[
                                                            pNum] ??
                                                        '$_currentSubjectFolder $_currentSubTopic 본문 및 기출 문항 (p.$pNum)'),
                                                maxLines: 4,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 9,
                                                  color: Colors.black87,
                                                  height: 1.35,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Wrap(
                                            spacing: 4,
                                            runSpacing: 4,
                                            children: [
                                              if (sCount > 0)
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 5,
                                                    vertical: 1,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                            0xFF1565C0)
                                                        .withValues(
                                                            alpha: 0.15),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            4),
                                                  ),
                                                  child: Text(
                                                    '✍️ 필기 $sCount획',
                                                    style: const TextStyle(
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color:
                                                          Color(0xFF1565C0),
                                                    ),
                                                  ),
                                                ),
                                              if (mCount > 0)
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 5,
                                                    vertical: 1,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                            0xFFD81B60)
                                                        .withValues(
                                                            alpha: 0.15),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            4),
                                                  ),
                                                  child: Text(
                                                    '🔒 가림막 $mCount',
                                                    style: const TextStyle(
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color:
                                                          Color(0xFFD81B60),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// ==========================================================================
  /// 시험 일정 폴더의 D-Day + 문서별 남은 페이지 + 미암기 가림막 수를 계산해
  /// 오늘 공부할 분량을 자동 배분해 주는 'AI 스터디 플래너 모달'
  /// ==========================================================================
  List<SubjectExamQuotaInput> _buildSubjectQuotaInputs() {
    final allMasks = _masksByPage.values.expand((e) => e).toList();
    final unmasteredCurrentMasks = allMasks
        .where((m) =>
            !m.isRevealed ||
            m.reviewSchedule.isDueNow ||
            m.reviewSchedule.lastScore < 85)
        .length;

    // 1) 현재 열려 있는 주력 과목 문서의 실제 페이지·회독·미암기 가림막·오답 수치 반영
    final int parsedDday = int.tryParse(
          RegExp(r'D-(\d+)').firstMatch(_examDdayLabel)?.group(1) ?? '12',
        ) ??
        12;

    return [
      SubjectExamQuotaInput(
        subjectName: _currentSubjectFolder,
        docTitle: _currentFileName,
        dDayRemaining: parsedDday,
        totalPages: _totalPages,
        currentPage: _currentPage,
        currentReadCount: _readCount,
        targetReadCount: _targetReadCount,
        unmasteredMaskCount: math.max(1, unmasteredCurrentMasks),
        wrongAnswerCardCount: _studyCards.length,
      ),
      const SubjectExamQuotaInput(
        subjectName: '유기화학 I',
        docTitle: '입체화학_거울상이성질체_요약.pdf',
        dDayRemaining: 5,
        totalPages: 28,
        currentPage: 10,
        currentReadCount: 1,
        targetReadCount: 3,
        unmasteredMaskCount: 4,
        wrongAnswerCardCount: 2,
      ),
      const SubjectExamQuotaInput(
        subjectName: '법학·행정학',
        docTitle: '핵심판례_기출분석.pdf',
        dDayRemaining: 19,
        totalPages: 64,
        currentPage: 30,
        currentReadCount: 2,
        targetReadCount: 3,
        unmasteredMaskCount: 2,
        wrongAnswerCardCount: 1,
      ),
    ];
  }

  /// 편성된 뽀모도로 타임블록 시간표 확인 및 로컬 알림·캘린더(.ics) 일정 등록 다이얼로그
  void _showPomodoroTimeTableAndCalendarDialog(
    AiStudyQuotaPlanResult plan, {
    DateTime? customStartTime,
  }) {
    final now = DateTime.now();
    DateTime startTime = customStartTime ??
        DateTime(now.year, now.month, now.day, now.hour, (now.minute ~/ 5) * 5)
            .add(const Duration(minutes: 10));

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final colorScheme = Theme.of(ctx).colorScheme;
            final blocks = _scheduleCalendarService
                .buildTimeBlockedPomodoroSchedule(
              plan: plan,
              firstSessionStart: startTime,
            );

            return AlertDialog(
              title: Row(
                children: [
                  Icon(
                    Icons.notifications_active_outlined,
                    color: colorScheme.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '오늘의 뽀모도로 타임블록 시간표 & 알림·캘린더 등록',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: ctx,
                        initialTime: TimeOfDay.fromDateTime(startTime),
                      );
                      if (picked != null) {
                        setDialogState(() {
                          startTime = DateTime(
                            now.year,
                            now.month,
                            now.day,
                            picked.hour,
                            picked.minute,
                          );
                        });
                      }
                    },
                    icon: const Icon(Icons.access_time, size: 15),
                    label: Text(
                      '첫 세션 시작: ${startTime.hour.toString().padLeft(2, "0")}:${startTime.minute.toString().padLeft(2, "0")}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 560,
                height: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer
                            .withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '총 ${blocks.length}개 뽀모도로 블록(25분 집중 + 5분 휴식, 4세션마다 15분 휴식)이 편성되었습니다. 각 블록 시작 시각에 태블릿 로컬 알림이 울리며, .ics 파일로 iPad/Android 기본 캘린더에 일괄 등록할 수 있습니다.',
                        style: const TextStyle(fontSize: 11, height: 1.4),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.builder(
                        itemCount: blocks.length,
                        itemBuilder: (ctx, idx) {
                          final b = blocks[idx];
                          return Card(
                            elevation: 0,
                            color: colorScheme.surfaceContainerLow,
                            margin: const EdgeInsets.only(bottom: 6),
                            child: ListTile(
                              dense: true,
                              leading: CircleAvatar(
                                radius: 14,
                                backgroundColor: colorScheme.primary,
                                child: Text(
                                  '#${b.blockOrder}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.onPrimary,
                                  ),
                                ),
                              ),
                              title: Text(
                                '${b.formattedTimeWindow}  |  ${b.subjectName} (${b.dDayBadge})',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                '${b.pageRangeLabel} · 가림막 ${b.targetMaskCount}개 인출 (${b.sessionIndexInSubject}/${b.totalSessionsInSubject}세션) → 종료 후 ${b.breakMinutesAfter}분 휴식',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('닫기'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final savedFile = await _scheduleCalendarService
                        .exportIcsCalendarFile(blocks);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '📅 캘린더 일정(.ics) 저장 완료 ($savedFile): Apple 캘린더·Google 캘린더에 ${blocks.length}개 세션과 10분 전 알림(VALARM)이 등록됩니다.',
                        ),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  icon: const Icon(Icons.event_available, size: 16),
                  label: const Text('캘린더(.ics) 일정 파일 내보내기'),
                ),
                FilledButton.icon(
                  onPressed: () async {
                    final count = await _scheduleCalendarService
                        .scheduleTabletLocalNotifications(blocks);
                    if (!mounted) return;
                    Navigator.of(ctx).pop();
                    setState(() {
                      _scheduledPomodoroBlocks
                        ..clear()
                        ..addAll(blocks);
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '🔔 태블릿 로컬 알림 $count건 예약 완료! 첫 알림은 ${blocks.first.formattedTimeWindow} [${blocks.first.subjectName}] 세션에 울립니다.',
                        ),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  icon: const Icon(
                    Icons.notifications_active,
                    size: 16,
                  ),
                  label: const Text('태블릿 로컬 알림 일괄 등록'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAiStudyPlannerModal() {
    int selectedDailyMinutes = 150;
    bool isRefiningWithGemini = false;
    final inputs = _buildSubjectQuotaInputs();
    AiStudyQuotaPlanResult currentPlan =
        _geminiService.computeMathematicalQuotaPlan(
      inputs: inputs,
      availableDailyMinutes: selectedDailyMinutes,
    );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setPlannerState) {
            final colorScheme = Theme.of(ctx).colorScheme;
            final completedTasks =
                currentPlan.tasks.where((t) => t.isCompletedToday).length;
            final totalTodayPages = currentPlan.tasks
                .fold<int>(0, (sum, t) => sum + t.todayPageQuota);
            final totalTodayMasks = currentPlan.tasks
                .fold<int>(0, (sum, t) => sum + t.todayMaskQuota);
            final totalTodayPomodoros = currentPlan.tasks.fold<int>(
                0, (sum, t) => sum + t.recommendedPomodoroSessions);

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.82,
              maxChildSize: 0.94,
              builder: (ctx, scrollController) {
                return Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 상단 헤더
                      Row(
                        children: [
                          Icon(
                            Icons.calendar_month_outlined,
                            color: colorScheme.primary,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'AI 일일 학습 할당량 플래너 (D-Day · 남은 페이지 · 미암기 가림막 연동)',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  '오늘 목표: 총 ${totalTodayPages}페이지 진도 · 미암기 가림막 ${totalTodayMasks}개 정복 · 뽀모도로 ${totalTodayPomodoros}세션',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: isRefiningWithGemini
                                ? null
                                : () async {
                                    setPlannerState(
                                        () => isRefiningWithGemini = true);
                                    final refined = await _geminiService
                                        .generateDailyStudyQuotaPlan(
                                      inputs: inputs,
                                      availableDailyMinutes:
                                          selectedDailyMinutes,
                                    );
                                    if (!ctx.mounted) return;
                                    setPlannerState(() {
                                      isRefiningWithGemini = false;
                                      currentPlan = refined;
                                    });
                                  },
                            icon: const Icon(Icons.auto_awesome, size: 15),
                            label: Text(
                              isRefiningWithGemini
                                  ? 'Gemini 분석 중...'
                                  : 'Gemini AI 정밀 재배분',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          const SizedBox(width: 6),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () {
                              _showPomodoroTimeTableAndCalendarDialog(
                                  currentPlan);
                            },
                            icon: const Icon(
                              Icons.notifications_active_outlined,
                              size: 15,
                            ),
                            label: Text(
                              _scheduledPomodoroBlocks.isNotEmpty
                                  ? '알림·캘린더 등록됨 (${_scheduledPomodoroBlocks.length}건)'
                                  : '알림 & 캘린더(.ics) 등록',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 1) 오늘 가용 순공 시간 슬라이더 (60분 ~ 300분)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  '오늘 가용 순공 시간 설정 (슬라이더 조절 시 과목별 분량 자동 재계산)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '${selectedDailyMinutes}분 (약 ${(selectedDailyMinutes / 60).toStringAsFixed(1)}시간 · ${(selectedDailyMinutes / 25).ceil()}뽀모도로)',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Slider(
                              value: selectedDailyMinutes.toDouble(),
                              min: 60,
                              max: 300,
                              divisions: 8,
                              label: '${selectedDailyMinutes}분',
                              onChanged: (val) {
                                setPlannerState(() {
                                  selectedDailyMinutes = val.round();
                                  currentPlan = _geminiService
                                      .computeMathematicalQuotaPlan(
                                    inputs: inputs,
                                    availableDailyMinutes:
                                        selectedDailyMinutes,
                                  );
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // 2) Gemini AI 배분 전략 총평 배너
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.tertiaryContainer
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.tips_and_updates_outlined,
                              size: 18,
                              color: colorScheme.onTertiaryContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                currentPlan.aiCoachHeadline,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.45,
                                  color: colorScheme.onTertiaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 3) 과목별 일일 할당량 카드 리스트
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '과목별 오늘의 할당량 리스트 (완료 $completedTasks / ${currentPlan.tasks.length})',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Text(
                            '긴급도(D-Day · 미암기 가림막) 순 자동 정렬',
                            style: TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          controller: scrollController,
                          itemCount: currentPlan.tasks.length,
                          itemBuilder: (ctx, i) {
                            final task = currentPlan.tasks[i];
                            final isUrgent = task.dDayRemaining <= 7;
                            return Card(
                              elevation: 0,
                              color: task.isCompletedToday
                                  ? colorScheme.surfaceContainerLow
                                      .withValues(alpha: 0.5)
                                  : (isUrgent
                                      ? colorScheme.errorContainer
                                          .withValues(alpha: 0.22)
                                      : colorScheme.surfaceContainerLow),
                              margin: const EdgeInsets.only(bottom: 10),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Checkbox(
                                          value: task.isCompletedToday,
                                          visualDensity:
                                              VisualDensity.compact,
                                          onChanged: (val) {
                                            setPlannerState(() {
                                              task.isCompletedToday =
                                                  val ?? false;
                                            });
                                          },
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isUrgent
                                                ? const Color(0xFFD81B60)
                                                : colorScheme.primary,
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            '${i + 1}순위 · ${task.dDayBadge}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            '${task.subjectName} (${task.docTitle})',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                              decoration:
                                                  task.isCompletedToday
                                                      ? TextDecoration
                                                          .lineThrough
                                                      : null,
                                            ),
                                          ),
                                        ),
                                        FilledButton.tonalIcon(
                                          style: FilledButton.styleFrom(
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          onPressed: () {
                                            Navigator.of(ctx).pop();
                                            setState(() {
                                              _currentSubjectFolder =
                                                  task.subjectName;
                                              _examDdayLabel =
                                                  '${task.subjectName} ${task.dDayBadge}';
                                              _remainingSeconds = 25 * 60;
                                              _isTimerRunning = false;
                                              _isHandwritingGradingMode =
                                                  true;
                                            });
                                            _jumpToCitedPage(task.startPage);
                                            _togglePomodoro();
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '🚀 [${task.subjectName}] 오늘 할당량(${task.pageRangeLabel} · 가림막 ${task.todayMaskQuota}개) 학습과 25분 뽀모도로 타이머를 시작합니다!',
                                                ),
                                                behavior:
                                                    SnackBarBehavior.floating,
                                              ),
                                            );
                                          },
                                          icon: const Icon(
                                            Icons.play_arrow,
                                            size: 16,
                                          ),
                                          label: const Text(
                                            '이 분량 바로 시작',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      children: [
                                        _buildQuotaMetricChip(
                                          ctx,
                                          icon: Icons.menu_book_outlined,
                                          label:
                                              '오늘 진도: ${task.pageRangeLabel}',
                                        ),
                                        _buildQuotaMetricChip(
                                          ctx,
                                          icon: Icons.visibility_off_outlined,
                                          label:
                                              '미암기 가림막: 오늘 ${task.todayMaskQuota}개 정복',
                                        ),
                                        _buildQuotaMetricChip(
                                          ctx,
                                          icon: Icons.timer_outlined,
                                          label:
                                              '배정 시간: ${task.allocatedMinutes}분 (${task.recommendedPomodoroSessions}뽀모도로)',
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'AI 전략: ${task.aiStrategyTip}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        height: 1.4,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildQuotaMetricChip(
    BuildContext context, {
    required IconData icon,
    required String label,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: colorScheme.primary),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// ==========================================================================
  /// 핵심 기능: 전사 세그먼트 구간([seg.startMs] ~ [seg.endMs]) 동안 그어진 모든 필기 획 찾기
  /// ==========================================================================
  List<NormalizedStroke> _findStrokesForTranscriptSegment(
    AudioTranscriptSegment seg,
  ) {
    final pageStrokes =
        _strokesByPage[seg.pageNumber] ?? const <NormalizedStroke>[];
    return pageStrokes
        .where((s) => s.overlapsTimeRange(seg.startMs, seg.endMs))
        .toList();
  }

  /// 전사 세그먼트 구간([seg])과 연동된 암기 가림막(NormalizedMaskRect) 목록 탐색
  List<NormalizedMaskRect> _findMasksForTranscriptSegment(
    AudioTranscriptSegment seg,
  ) {
    final pageMasks =
        _masksByPage[seg.pageNumber] ?? const <NormalizedMaskRect>[];
    return pageMasks.where((m) => m.matchesTranscriptSegment(seg)).toList();
  }

  /// 키워드(query)로 전사 대본을 검색했을 때:
  /// 1) 매칭된 세그먼트들을 찾고,
  /// 2) 그 세그먼트들을 말씀하실 때 그었던 필기 획들의 ID를 `_highlightedStrokeIds`에 담아 동시 하이라이트하고,
  /// 3) 첫 번째 매칭된 세그먼트의 녹음 시점(`startMs`) 및 PDF 페이지로 즉시 동기화합니다.
  void _applyTranscriptKeywordSearch(
    String query, {
    bool jumpAudioToFirstMatch = true,
  }) {
    final trimmed = query.trim();
    final matchedSegments = _lectureAudioSession.segments
        .where((seg) => seg.matchesKeyword(trimmed))
        .toList();

    final matchedStrokeIds = <String>{};
    if (trimmed.isNotEmpty) {
      for (final seg in matchedSegments) {
        final overlappingStrokes = _findStrokesForTranscriptSegment(seg);
        for (final s in overlappingStrokes) {
          matchedStrokeIds.add(s.strokeId);
        }
      }
    }

    setState(() {
      _activeTranscriptSearchQuery = trimmed;
      _highlightedStrokeIds
        ..clear()
        ..addAll(matchedStrokeIds);

      if (trimmed.isNotEmpty &&
          jumpAudioToFirstMatch &&
          matchedSegments.isNotEmpty) {
        final firstSeg = matchedSegments.first;
        _currentPage = firstSeg.pageNumber.clamp(1, _totalPages);
        // 매칭된 첫 세그먼트 안에 연동된 필기 획이 있으면 그 획을 그리기 시작한 정확한 시점으로 점프
        final firstStrokes = _findStrokesForTranscriptSegment(firstSeg);
        _currentAudioPositionMs = firstStrokes.isNotEmpty &&
                firstStrokes.first.audioStartMs != null
            ? firstStrokes.first.audioStartMs!
            : firstSeg.startMs;
      }
    });

    if (trimmed.isNotEmpty &&
        jumpAudioToFirstMatch &&
        matchedSegments.isNotEmpty &&
        _loadedPdfBytes != null) {
      _pdfViewerController.jumpToPage(_currentPage);
    }
  }

  /// ==========================================================================
  /// 오디오북 플레이리스트 생성 및 무공백(Gap-Skipping) 연속 재생 엔진
  /// ==========================================================================
  void _buildAndStartAudiobookPlaylist({
    String? keywordFilter,
    bool strokeLinkedOnly = false,
    bool enableVoiceClozeQuiz = false,
  }) {
    final query = (keywordFilter ?? _activeTranscriptSearchQuery).trim();
    final List<AudiobookPlaylistTrack> tracks = [];

    for (int i = 0; i < _lectureAudioSession.segments.length; i++) {
      final seg = _lectureAudioSession.segments[i];
      if (query.isNotEmpty && !seg.matchesKeyword(query)) {
        continue;
      }
      final strokes = _findStrokesForTranscriptSegment(seg);
      final masks = _findMasksForTranscriptSegment(seg);
      if (strokeLinkedOnly && strokes.isEmpty) {
        continue;
      }
      if (enableVoiceClozeQuiz && masks.isEmpty) {
        continue;
      }
      tracks.add(
        AudiobookPlaylistTrack(
          trackId: 'track_${seg.startMs}_$i',
          segment: seg,
          linkedStrokes: strokes,
          linkedMasks: masks,
          sourceFilterLabel: enableVoiceClozeQuiz
              ? '음성 빈칸 퀴즈'
              : (query.isNotEmpty
                  ? '키워드 "$query"'
                  : (strokeLinkedOnly ? '필기 연동 구간' : '전체 핵심 세그먼트')),
        ),
      );
    }

    if (tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enableVoiceClozeQuiz
                ? '암기 가림막(Masking Tape)이 연결된 오디오 구간이 없습니다.'
                : '조건에 맞는 오디오북 재생 구간이 없습니다. 다른 키워드를 선택해 보세요.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (enableVoiceClozeQuiz) {
      // 음성 빈칸 퀴즈 시작 시 연결된 모든 가림막을 다시 가려(isRevealed = false) 실전 인출 테스트 준비
      for (final t in tracks) {
        for (final m in t.linkedMasks) {
          m.isRevealed = false;
        }
      }
    }

    setState(() {
      _audiobookPlaylist
        ..clear()
        ..addAll(tracks);
      _currentPlaylistTrackIndex = 0;
      _isPlaylistModeActive = true;
      _isVoiceClozeQuizMode = enableVoiceClozeQuiz;
      _activeQuizPausedMask = null;
      _quizTriggeredTrackIds.clear();
      _playlistTitle = enableVoiceClozeQuiz
          ? '음성 빈칸 퀴즈 오디오북 (${tracks.length}문항)'
          : (query.isNotEmpty
              ? '"$query" 하이라이트 오디오북 (${tracks.length}구간)'
              : (strokeLinkedOnly
                  ? '필기 연동 하이라이트 오디오북 (${tracks.length}구간)'
                  : '강의 전체 핵심 오디오북 (${tracks.length}구간)'));
    });

    _activatePlaylistTrack(0, startPlayback: true);
  }

  /// 암기 가림막(Masking Tape)과 오디오북 트랙을 결합해 정답 발화 직전 일시정지하는 음성 빈칸 퀴즈 시작
  void _startVoiceClozeQuizPlaylist({String? keywordFilter}) {
    _buildAndStartAudiobookPlaylist(
      keywordFilter: keywordFilter,
      strokeLinkedOnly: false,
      enableVoiceClozeQuiz: true,
    );
  }

  /// 음성 빈칸 퀴즈에서 일시정지된 가림막의 정답을 개봉하고 교수님 정답 해설 음성을 즉시 이어 재생
  void _revealQuizMaskAndResumeAudio(NormalizedMaskRect mask) {
    setState(() {
      mask.isRevealed = true;
      if (_activeQuizPausedMask?.maskId == mask.maskId) {
        _activeQuizPausedMask = null;
      }
      _voiceQuizSolvedCount++;
      _isPlayingAudio = true;
    });
    _persistCurrentPageAnnotations();
    _startAudioClock();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '정답 확인 [${mask.hintKeyword}]! 교수님 설명 음성과 필기 리플레이를 이어서 재생합니다.',
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 가림막(NormalizedMaskRect) 위에 애플펜슬·S펜으로 쓴 손글씨를 캡처해 Gemini로 채점
  Future<void> _gradeMaskHandwritingWithGemini(NormalizedMaskRect mask) async {
    if (!mask.hasHandwrittenInk || mask.isGradingInProgress) return;

    setState(() {
      mask.isGradingInProgress = true;
    });

    final Uint8List? pngBytes = await mask.renderHandwritingToPngBytes();
    final String pageContext = _extractedPageTexts[_currentPage] ??
        '생물학개론 제3장 세포호흡과 산화적 인산화 기출문제 ($_currentPage페이지)';

    final HandwrittenMaskGradeResult result =
        await _geminiService.gradeHandwrittenMaskAnswer(
      mask: mask,
      handwritingPngBytes: pngBytes,
      pageTextContext: pageContext,
    );

    if (!mounted) return;

    final bool wasQuizPausedTarget =
        _activeQuizPausedMask?.maskId == mask.maskId;

    setState(() {
      mask.isGradingInProgress = false;
      mask.lastGradeResult = result;
      mask.reviewSchedule.recordAttemptScore(result.score);
      if (result.isCorrect) {
        mask.isRevealed = true;
        if (wasQuizPausedTarget) {
          _activeQuizPausedMask = null;
          _voiceQuizSolvedCount++;
          _isPlayingAudio = true;
        }
      }
    });

    _persistCurrentPageAnnotations();

    if (result.isCorrect && wasQuizPausedTarget) {
      _startAudioClock();
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.isCorrect
              ? '✅ Gemini 손글씨 채점 정답 (${result.score}점) | 인식된 필기: "${result.recognizedHandwriting}"
${result.feedback}'
              : '❌ Gemini 손글씨 채점 (${result.score}점) | 인식된 필기: "${result.recognizedHandwriting}"
${result.feedback}',
        ),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        action: !result.isCorrect
            ? SnackBarAction(
                label: '정답 개봉',
                onPressed: () {
                  if (wasQuizPausedTarget) {
                    _revealQuizMaskAndResumeAudio(mask);
                  } else {
                    setState(() => mask.isRevealed = true);
                    _persistCurrentPageAnnotations();
                  }
                },
              )
            : null,
      ),
    );
  }

  /// 과목별 통합 오답노트(AI 올가미 오답 + 에빙하우스 약점 가림막) PDF 생성 및 뷰어 로드
  Future<void> _generateAndOpenMasterWrongAnswerBookPdf() async {
    setState(() => _isExportingPdf = true);
    final allMasks = _masksByPage.values.expand((e) => e).toList();

    final Uint8List pdfBytes =
        await _exportService.exportSubjectMasterWrongAnswerBookPdf(
      subjectFolder: _currentSubjectFolder,
      examDdayLabel: _examDdayLabel,
      studyCards: _studyCards,
      masks: allMasks,
    );

    if (!mounted) return;
    setState(() {
      _isExportingPdf = false;
      _loadedPdfBytes = pdfBytes;
      _currentPage = 1;
      _totalPages = 1;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '📕 [$_currentSubjectFolder] 통합 오답노트 PDF 생성 완료 (올가미 오답 ${_studyCards.length}문항 + 가림막 ${allMasks.length}개)',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 에빙하우스 복습 주기가 도래했거나 손글씨 채점 점수가 85점 미만인 약점 가림막만 초기화하여
  /// 손글씨 빈칸 재시험(Re-Test) + 오디오북 빈칸 퀴즈로 즉시 시작합니다.
  void _startWeakMaskHandwritingRetest() {
    final allMasks = _masksByPage.values.expand((e) => e).toList();
    final weakMasks = allMasks
        .where((m) => m.reviewSchedule.isDueNow || m.reviewSchedule.lastScore < 85)
        .toList();
    final targetList = weakMasks.isNotEmpty ? weakMasks : allMasks;
    if (targetList.isEmpty) return;

    setState(() {
      _isHandwritingGradingMode = true;
      for (final m in targetList) {
        m.isRevealed = false;
        m.clearHandwriting();
      }
    });

    final firstTarget = targetList.first;
    _jumpToCitedPage(firstTarget.pageNumber);
    _startVoiceClozeQuizPlaylist();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '✍️ 에빙하우스 약점 가림막 재시험 시작 (${targetList.length}개 빈칸): 가림막 위에 펜슬로 정답을 적어 AI 채점을 받아보세요.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// ==========================================================================
  /// 시험 당일 아침 10분 만에 끝내는 'D-Day 초고속 오답·빈칸 타임어택 모의고사 모드'
  /// ==========================================================================
  void _startDdayTimeAttackMockExamModal() {
    final allMasks = _masksByPage.values.expand((e) => e).toList();
    final List<({
      String id,
      String badge,
      int pageNumber,
      String questionPrompt,
      String expectedAnswer,
      NormalizedMaskRect? linkedMask,
    })> quizDeck = [];

    for (final m in allMasks) {
      quizDeck.add((
        id: 'mask_${m.maskId}',
        badge: '암기 가림막 빈칸 (p.${m.pageNumber})',
        pageNumber: m.pageNumber,
        questionPrompt:
            '[p.${m.pageNumber} 빈칸 인출] 이 영역의 핵심 출제 키워드를 즉시 답하세요.',
        expectedAnswer: m.hintKeyword,
        linkedMask: m,
      ));
    }

    for (final c in _studyCards) {
      quizDeck.add((
        id: 'card_${c.cardId}',
        badge: 'AI 올가미 쌍둥이 변형 (p.${c.pageNumber})',
        pageNumber: c.pageNumber,
        questionPrompt: c.twinQuestion,
        expectedAnswer: c.twinAnswer,
        linkedMask: null,
      ));
    }

    if (quizDeck.isEmpty) return;

    int currentIdx = 0;
    int correctCount = 0;
    int remainingSec = quizDeck.length * 25; // 문항당 25초 타임어택
    bool isAnswerRevealed = false;
    bool isFinished = false;
    Timer? attackTimer;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            attackTimer ??=
                Timer.periodic(const Duration(seconds: 1), (timer) {
              if (!ctx.mounted) {
                timer.cancel();
                return;
              }
              setModalState(() {
                if (remainingSec > 0 && !isFinished) {
                  remainingSec--;
                } else {
                  isFinished = true;
                  timer.cancel();
                }
              });
            });

            final colorScheme = Theme.of(ctx).colorScheme;
            final currentItem =
                quizDeck[currentIdx.clamp(0, quizDeck.length - 1)];

            void handleGradeSelection(bool passed) {
              if (currentItem.linkedMask != null) {
                currentItem.linkedMask!.reviewSchedule
                    .recordAttemptScore(passed ? 98 : 40);
                currentItem.linkedMask!.isRevealed = passed;
              }
              setModalState(() {
                if (passed) correctCount++;
                if (currentIdx + 1 < quizDeck.length) {
                  currentIdx++;
                  isAnswerRevealed = false;
                } else {
                  isFinished = true;
                  attackTimer?.cancel();
                }
              });
              setState(() {});
              _persistCurrentPageAnnotations();
            }

            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.bolt, color: colorScheme.primary, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isFinished
                          ? '⚡ D-Day 타임어택 모의고사 결과 리포트'
                          : '⚡ D-Day 초고속 오답·빈칸 타임어택 (${currentIdx + 1}/${quizDeck.length})',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: remainingSec <= 15
                          ? colorScheme.errorContainer
                          : colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '남은 시간 ${_formatMs(remainingSec * 1000)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: remainingSec <= 15
                            ? colorScheme.onErrorContainer
                            : colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 480,
                child: isFinished
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  '최종 득점: $correctCount / ${quizDeck.length} 문항 (${((correctCount / quizDeck.length) * 100).round()}%)',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  '문항별 정오답 결과가 에빙하우스 SM-2 복습 주기에 즉시 반영되었습니다.',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(
                            value: (currentIdx + 1) / quizDeck.length,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              currentItem.badge,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            currentItem.questionPrompt,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (isAnswerRevealed)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: colorScheme.primaryContainer
                                    .withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '정답: ${currentItem.expectedAnswer}',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.onPrimaryContainer,
                                ),
                              ),
                            )
                          else
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.tonalIcon(
                                onPressed: () => setModalState(
                                  () => isAnswerRevealed = true,
                                ),
                                icon: const Icon(
                                  Icons.visibility_outlined,
                                  size: 17,
                                ),
                                label: const Text('정답 즉시 확인'),
                              ),
                            ),
                        ],
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    attackTimer?.cancel();
                    Navigator.of(ctx).pop();
                  },
                  child: Text(isFinished ? '닫기' : '모의고사 종료'),
                ),
                if (!isFinished && isAnswerRevealed) ...[
                  OutlinedButton.icon(
                    onPressed: () => handleGradeSelection(false),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('헷갈림 (오늘 재복습)'),
                  ),
                  FilledButton.icon(
                    onPressed: () => handleGradeSelection(true),
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('완벽 암기 (SM-2 통과)'),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  /// ==========================================================================
  /// 전체 워크스페이스 데이터(.studynote JSON 아카이브) 백업 내보내기 및 복원
  /// ==========================================================================
  Map<String, dynamic> _buildFullWorkspaceBackupJson() {
    final strokesMap = <String, dynamic>{};
    _strokesByPage.forEach((page, list) {
      strokesMap[page.toString()] = list.map((s) => s.toJson()).toList();
    });

    final masksMap = <String, dynamic>{};
    _masksByPage.forEach((page, list) {
      masksMap[page.toString()] = list.map((m) => m.toJson()).toList();
    });

    return {
      'schemaVersion': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'currentDocId': _currentDocId,
      'currentFileName': _currentFileName,
      'currentSubjectFolder': _currentSubjectFolder,
      'currentSubTopic': _currentSubTopic,
      'currentDocType': _currentDocType,
      'examDdayLabel': _examDdayLabel,
      'readCount': _readCount,
      'folders': _folders.map((f) => f.toJson()).toList(),
      'strokesByPage': strokesMap,
      'masksByPage': masksMap,
      'studyCards': _studyCards.map((c) => c.toJson()).toList(),
      'audioSession': _lectureAudioSession.toJson(),
    };
  }

  Future<void> _exportStudyNoteArchive() async {
    final backupPayload = _buildFullWorkspaceBackupJson();
    final jsonString = const JsonEncoder.withIndent('  ').convert(backupPayload);
    final archiveBytes = Uint8List.fromList(utf8.encode(jsonString));
    final cleanName = _currentFileName.replaceAll('.pdf', '');
    final fileName = '${cleanName}_전체백업.studynote.json';

    try {
      await FilePicker.platform.saveFile(
        dialogTitle: 'AI 스터디 노트 전체 백업(.studynote.json) 저장',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: archiveBytes,
      );
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '💾 전체 백업 아카이브($fileName) 생성 완료: 필기·가림막(SM-2)·오답카드·오디오북 세션이 모두 패키징되었습니다.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _importAndRestoreStudyNoteArchive() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final bytes = res.files.single.bytes;
      if (bytes == null) return;

      final decoded =
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

      setState(() {
        _currentDocId =
            (decoded['currentDocId'] as String?) ?? _currentDocId;
        _currentFileName =
            (decoded['currentFileName'] as String?) ?? _currentFileName;
        _currentSubjectFolder =
            (decoded['currentSubjectFolder'] as String?) ??
                _currentSubjectFolder;
        _currentSubTopic =
            (decoded['currentSubTopic'] as String?) ?? _currentSubTopic;
        _examDdayLabel =
            (decoded['examDdayLabel'] as String?) ?? _examDdayLabel;
        _readCount = (decoded['readCount'] as num?)?.toInt() ?? _readCount;

        final rawStrokes =
            decoded['strokesByPage'] as Map<String, dynamic>?;
        if (rawStrokes != null) {
          _strokesByPage.clear();
          rawStrokes.forEach((pageKey, listVal) {
            final pageNum = int.tryParse(pageKey) ?? 1;
            final list = (listVal as List<dynamic>)
                .map((e) => NormalizedStroke.fromJson(
                    e as Map<String, dynamic>))
                .toList();
            _strokesByPage[pageNum] = list;
          });
        }

        final rawMasks = decoded['masksByPage'] as Map<String, dynamic>?;
        if (rawMasks != null) {
          _masksByPage.clear();
          rawMasks.forEach((pageKey, listVal) {
            final pageNum = int.tryParse(pageKey) ?? 1;
            final list = (listVal as List<dynamic>)
                .map((e) =>
                    NormalizedMaskRect.fromJson(e as Map<String, dynamic>))
                .toList();
            _masksByPage[pageNum] = list;
          });
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 백업 아카이브(.studynote.json) 복원이 완료되었습니다.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('백업 파일 복원 중 오류가 발생했습니다: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// ==========================================================================
  /// 과목별 회독률 · 에빙하우스 암기율 · 뽀모도로 순공 시간 '학습 통계 대시보드 모달'
  /// ==========================================================================
  void _showStudyAnalyticsDashboardModal() {
    final allMasks = _masksByPage.values.expand((e) => e).toList();
    final allStrokes = _strokesByPage.values.expand((e) => e).toList();
    final masteredMasks = allMasks
        .where((m) => m.isRevealed || m.reviewSchedule.lastScore >= 85)
        .length;
    final masteryPercent = allMasks.isEmpty
        ? 100
        : ((masteredMasks / allMasks.length) * 100).round();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.76,
          maxChildSize: 0.92,
          builder: (ctx, scrollController) {
            return Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.insights,
                        color: colorScheme.primary,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '과목별 회독·에빙하우스 기억 유지율·순공 통계 대시보드',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '현재 문서: $_currentSubjectFolder > $_currentSubTopic ($_examDdayLabel)',
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _importAndRestoreStudyNoteArchive();
                        },
                        icon: const Icon(Icons.upload_file, size: 15),
                        label: const Text(
                          '백업 복원',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 6),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _exportStudyNoteArchive();
                        },
                        icon: const Icon(Icons.save_alt, size: 15),
                        label: const Text(
                          '.studynote 전체 백업 저장',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      children: [
                        // 1. 핵심 4대 KPI 카드
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _buildKpiStatCard(
                              ctx,
                              title: '목표 회독 달성률',
                              value:
                                  '$_readCount / $_targetReadCount 회독 (${((_readCount / _targetReadCount) * 100).round()}%)',
                              subtitle: '마지막 페이지 도달 시 자동 증가',
                              icon: Icons.auto_stories,
                            ),
                            _buildKpiStatCard(
                              ctx,
                              title: '에빙하우스 암기 완료율',
                              value:
                                  '$masteryPercent% ($masteredMasks/${allMasks.length} 가림막)',
                              subtitle: 'SM-2 손글씨 85점 이상 통과 기준',
                              icon: Icons.psychology_outlined,
                            ),
                            _buildKpiStatCard(
                              ctx,
                              title: '음성 연동 필기 & 판서 스티커',
                              value:
                                  '필기 ${allStrokes.length}획 · 스티커 ${_currentPageBoardStickers.length}장',
                              subtitle: '오디오 세그먼트 ${_lectureAudioSession.segments.length}개 동기화됨',
                              icon: Icons.draw_outlined,
                            ),
                            _buildKpiStatCard(
                              ctx,
                              title: 'AI 올가미 쌍둥이 오답 정복',
                              value: '${_studyCards.length}문항 생성됨',
                              subtitle: '음성 빈칸 퀴즈 인출 $_voiceQuizSolvedCount회 성공',
                              icon: Icons.quiz_outlined,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // 2. 주간 순공 시간 & 에빙하우스 기억 유지율 추이 커스텀 차트
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '최근 7일 뽀모도로 순공 시간(막대) & 에빙하우스 기억 유지율(곡선)',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 150,
                                width: double.infinity,
                                child: CustomPaint(
                                  painter: StudyAnalyticsChartPainter(
                                    dailyStudyMinutes: const [
                                      95,
                                      120,
                                      85,
                                      140,
                                      165,
                                      130,
                                      180,
                                    ],
                                    retentionRates: const [
                                      0.62,
                                      0.68,
                                      0.65,
                                      0.76,
                                      0.84,
                                      0.88,
                                      0.94,
                                    ],
                                    barColor: colorScheme.primary,
                                    lineColor: const Color(0xFFD81B60),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildKpiStatCard(
    BuildContext context, {
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 240,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 10,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 개별 전사 세그먼트를 사용자 정의 오디오북 플레이리스트 큐에 추가하거나 제거
  void _toggleSegmentInPlaylist(AudioTranscriptSegment seg) {
    final existingIdx = _audiobookPlaylist.indexWhere(
      (t) =>
          t.segment.startMs == seg.startMs &&
          t.segment.pageNumber == seg.pageNumber,
    );

    setState(() {
      if (existingIdx >= 0) {
        _audiobookPlaylist.removeAt(existingIdx);
        if (_audiobookPlaylist.isEmpty) {
          _isPlaylistModeActive = false;
          _currentPlaylistTrackIndex = 0;
        } else if (_currentPlaylistTrackIndex >= _audiobookPlaylist.length) {
          _currentPlaylistTrackIndex = _audiobookPlaylist.length - 1;
        }
      } else {
        final strokes = _findStrokesForTranscriptSegment(seg);
        final masks = _findMasksForTranscriptSegment(seg);
        _audiobookPlaylist.add(
          AudiobookPlaylistTrack(
            trackId: 'custom_${seg.startMs}',
            segment: seg,
            linkedStrokes: strokes,
            linkedMasks: masks,
            sourceFilterLabel: '선택 보관함',
          ),
        );
        _audiobookPlaylist.sort(
          (a, b) => a.effectiveStartMs.compareTo(b.effectiveStartMs),
        );
        _playlistTitle = '나만의 하이라이트 오디오북 (${_audiobookPlaylist.length}구간)';
      }
    });
  }

  /// 플레이리스트의 [index]번 트랙으로 즉시 이동하고 페이지·필기 하이라이트를 동기화
  void _activatePlaylistTrack(int index, {bool startPlayback = true}) {
    if (_audiobookPlaylist.isEmpty) return;
    final safeIdx = index.clamp(0, _audiobookPlaylist.length - 1);
    final track = _audiobookPlaylist[safeIdx];

    setState(() {
      _currentPlaylistTrackIndex = safeIdx;
      _isPlaylistModeActive = true;
      _isRecordingAudio = false;
      _currentPage = track.segment.pageNumber.clamp(1, _totalPages);
      _currentAudioPositionMs = track.effectiveStartMs;
      _highlightedStrokeIds
        ..clear()
        ..addAll(track.linkedStrokes.map((s) => s.strokeId));
      if (startPlayback) {
        _isPlayingAudio = true;
      }
    });

    if (_loadedPdfBytes != null) {
      _pdfViewerController.jumpToPage(_currentPage);
    }
    _loadAndMergeCurrentPageFromRepo();

    if (startPlayback) {
      _startAudioClock();
    }
  }

  /// 플레이리스트 이전/다음 트랙 스킵
  void _skipPlaylistTrack(int delta) {
    if (_audiobookPlaylist.isEmpty) return;
    int nextIdx = _currentPlaylistTrackIndex + delta;
    if (nextIdx >= _audiobookPlaylist.length) {
      nextIdx = _playlistLoopEnabled ? 0 : _audiobookPlaylist.length - 1;
    } else if (nextIdx < 0) {
      nextIdx = _playlistLoopEnabled ? _audiobookPlaylist.length - 1 : 0;
    }
    _activatePlaylistTrack(nextIdx, startPlayback: _isPlayingAudio);
  }

  /// 재생 배속 순환 (1.0x -> 1.25x -> 1.5x -> 2.0x -> 1.0x)
  void _cyclePlaybackSpeed() {
    const speeds = [1.0, 1.25, 1.5, 2.0];
    final currentIdx = speeds.indexOf(_playbackSpeed);
    final nextSpeed = speeds[(currentIdx + 1) % speeds.length];
    setState(() {
      _playbackSpeed = nextSpeed;
    });
  }

  /// 오디오북 플레이리스트 연속 재생 모드 종료
  void _stopAudiobookPlaylist() {
    setState(() {
      _isPlaylistModeActive = false;
      _isVoiceClozeQuizMode = false;
      _activeQuizPausedMask = null;
      _quizTriggeredTrackIds.clear();
      _isPlayingAudio = false;
    });
    _audioClockTimer?.cancel();
  }

  /// ==========================================================================
  /// 선택한 오디오북 플레이리스트 구간들의 전사 텍스트 + 필기 요약을 모아
  /// 시험 직전 1페이지 핵심 요약본(1-Page Cheat Sheet) 생성 및 모달/PDF 내보내기
  /// ==========================================================================
  Future<void> _generateAndShowOnePageCheatSheet({
    String? keywordFilter,
  }) async {
    List<AudiobookPlaylistTrack> targetTracks =
        List<AudiobookPlaylistTrack>.from(_audiobookPlaylist);

    if (targetTracks.isEmpty) {
      final query = (keywordFilter ?? _activeTranscriptSearchQuery).trim();
      for (int i = 0; i < _lectureAudioSession.segments.length; i++) {
        final seg = _lectureAudioSession.segments[i];
        if (query.isNotEmpty && !seg.matchesKeyword(query)) continue;
        targetTracks.add(
          AudiobookPlaylistTrack(
            trackId: 'sheet_track_${seg.startMs}_$i',
            segment: seg,
            linkedStrokes: _findStrokesForTranscriptSegment(seg),
            linkedMasks: _findMasksForTranscriptSegment(seg),
            sourceFilterLabel: query.isNotEmpty ? '키워드 "$query"' : '전체 핵심 구간',
          ),
        );
      }
    }

    if (targetTracks.isEmpty) return;

    setState(() => _isGeneratingCheatSheet = true);

    final OnePagePlaylistCheatSheet cheatSheet =
        await _geminiService.generateOnePagePlaylistCheatSheet(
      subjectFolder: _currentSubjectFolder,
      subTopic: _currentSubTopic,
      examDdayLabel: _examDdayLabel,
      playlistTracks: targetTracks,
    );

    if (!mounted) return;

    setState(() {
      _isGeneratingCheatSheet = false;
      _latestOnePageCheatSheet = cheatSheet;
      _notebookQaHistory.insert(
        0,
        NotebookQaAnswer(
          question:
              '[시험 직전 1페이지 요약본] ${cheatSheet.sheetTitle} (${cheatSheet.trackItems.length}개 오디오북 트랙 결합)',
          answer:
              '${cheatSheet.ultraShortExecutiveTakeaway}\n\n[필수 암기 빈칸 체크리스트]\n${cheatSheet.mustMemorizeChecklist.map((c) => "✓ $c").join("\n")}',
          citedPages: cheatSheet.trackItems
              .map((t) => t.pageNumber)
              .toSet()
              .toList(),
        ),
      );
    });

    _showOnePageCheatSheetModal(cheatSheet);
  }

  /// 1페이지 핵심 요약본의 트랙 카드를 탭했을 때 원본 PDF 페이지와 교수님 녹음 시점으로 즉시 양방향 점프
  void _jumpToOriginalPageAndAudioFromCheatSheet(CheatSheetTrackItem item) {
    final targetPage = item.pageNumber.clamp(1, _totalPages);
    final matchingSeg = _lectureAudioSession.segments.firstWhere(
      (s) =>
          s.pageNumber == item.pageNumber &&
          (s.formattedRange == item.timeRange || s.startMs == item.startMs),
      orElse: () => AudioTranscriptSegment(
        startMs: item.startMs,
        endMs: item.endMs,
        pageNumber: targetPage,
        transcriptText: item.condensedPoint,
        keyConceptTag: item.keyConcept,
      ),
    );
    final strokes = _findStrokesForTranscriptSegment(matchingSeg);

    setState(() {
      _currentPage = targetPage;
      _isRecordingAudio = false;
      _currentAudioPositionMs = strokes.isNotEmpty &&
              strokes.first.audioStartMs != null
          ? strokes.first.audioStartMs!
          : matchingSeg.startMs;
      _highlightedStrokeIds
        ..clear()
        ..addAll(strokes.map((s) => s.strokeId));
      _isPlayingAudio = true;
    });

    if (_loadedPdfBytes != null) {
      _pdfViewerController.jumpToPage(targetPage);
    }
    _loadAndMergeCurrentPageFromRepo();
    _startAudioClock();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '1p 요약본 딥링크 점프: 원본 p.$targetPage [${item.timeRange}] 음성 재생 및 연동 필기 ${strokes.length}획 하이라이트',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showOnePageCheatSheetModal(OnePagePlaylistCheatSheet sheet) {
    bool blindClozeBlanksInPreview = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final colorScheme = Theme.of(ctx).colorScheme;
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.78,
              maxChildSize: 0.94,
              builder: (ctx, scrollController) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.auto_stories_outlined,
                            color: colorScheme.primary,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  sheet.sheetTitle,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  '${sheet.subjectAndTopic} · ${sheet.examDdayLabel} · 오디오북 ${sheet.trackItems.length}개 구간 + 손필기 통합',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          FilterChip(
                            label: const Text(
                              '빈칸 가리기 테스트',
                              style: TextStyle(fontSize: 11),
                            ),
                            selected: blindClozeBlanksInPreview,
                            visualDensity: VisualDensity.compact,
                            onSelected: (val) => setModalState(
                              () => blindClozeBlanksInPreview = val,
                            ),
                          ),
                          const SizedBox(width: 6),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () async {
                              final pdfBytes = await _exportService
                                  .exportOnePageCheatSheetPdf(sheet);
                              if (!mounted) return;
                              Navigator.of(ctx).pop();
                              setState(() {
                                _loadedPdfBytes = pdfBytes;
                                _currentPage = 1;
                                _totalPages = 1;
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    '시험 직전 1페이지 핵심 요약본 PDF가 생성되어 메인 캔버스에 로드되었습니다.',
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.picture_as_pdf_outlined,
                              size: 16,
                            ),
                            label: const Text(
                              '1p 요약 PDF로 캔버스에 열기',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      Expanded(
                        child: ListView(
                          controller: scrollController,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: colorScheme.primaryContainer
                                    .withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '시험장 입실 5분 전 핵심 3줄 총평',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    sheet.ultraShortExecutiveTakeaway,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '선택된 오디오북 구간별 전사 텍스트 + 필기 요약',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ...sheet.trackItems.map((item) {
                              return Card(
                                elevation: 0,
                                color: colorScheme.surfaceContainerLow,
                                margin: const EdgeInsets.only(bottom: 8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () {
                                    Navigator.of(ctx).pop();
                                    _jumpToOriginalPageAndAudioFromCheatSheet(
                                        item);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: colorScheme.primary,
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              '트랙 #${item.trackOrder} (${item.timeRange})',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                color: colorScheme.onPrimary,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'p.${item.pageNumber} · ${item.keyConcept}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const Spacer(),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFD81B60)
                                                  .withValues(alpha: 0.14),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              '필기: ${item.strokeNoteSummary}',
                                              style: const TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                color: Color(0xFFD81B60),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        item.condensedPoint,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          height: 1.45,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.visibility_off_outlined,
                                            size: 14,
                                            color: Color(0xFF2575FC),
                                          ),
                                          const SizedBox(width: 4),
                                          const Text(
                                            '빈칸 핵심 키워드: ',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          InkWell(
                                            onTap: () => setModalState(
                                              () => blindClozeBlanksInPreview =
                                                  !blindClozeBlanksInPreview,
                                            ),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: blindClozeBlanksInPreview
                                                    ? const Color(0xFF2575FC)
                                                    : const Color(0xFF2575FC)
                                                        .withValues(
                                                            alpha: 0.15),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                blindClozeBlanksInPreview
                                                    ? '[ ❓ 탭하여 정답 확인 ]'
                                                    : item.clozeBlankKeyword,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color:
                                                      blindClozeBlanksInPreview
                                                          ? Colors.white
                                                          : const Color(
                                                              0xFF0D47A1),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const Spacer(),
                                          ActionChip(
                                            avatar: const Icon(
                                              Icons.play_circle_outline,
                                              size: 15,
                                            ),
                                            label: Text(
                                              '원본 p.${item.pageNumber} & 음성 점프',
                                              style: const TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () {
                                              Navigator.of(ctx).pop();
                                              _jumpToOriginalPageAndAudioFromCheatSheet(
                                                  item);
                                            },
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              );
                            }),
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: colorScheme.tertiaryContainer
                                    .withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '필수 암기 공식 & 빈칸 체크리스트',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  ...sheet.mustMemorizeChecklist.map(
                                    (check) => Padding(
                                      padding: const EdgeInsets.only(bottom: 4),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.check_circle_outline,
                                            size: 15,
                                            color: colorScheme.tertiary,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              check,
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// 전사 텍스트 내부의 검색 키워드(query) 일치 구간을 노란색/주황색 형광펜 스타일 TextSpan으로 강조
  TextSpan _buildHighlightedTextSpan({
    required String fullText,
    required String query,
    required Color baseColor,
    required Color highlightBgColor,
    required Color highlightTextColor,
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return TextSpan(
        text: fullText,
        style: TextStyle(fontSize: 12, height: 1.45, color: baseColor),
      );
    }

    final lowerText = fullText.toLowerCase();
    final lowerQuery = trimmed.toLowerCase();
    final List<TextSpan> spans = [];
    int start = 0;

    while (true) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index < 0) {
        spans.add(
          TextSpan(
            text: fullText.substring(start),
            style: TextStyle(fontSize: 12, height: 1.45, color: baseColor),
          ),
        );
        break;
      }
      if (index > start) {
        spans.add(
          TextSpan(
            text: fullText.substring(start, index),
            style: TextStyle(fontSize: 12, height: 1.45, color: baseColor),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: fullText.substring(index, index + trimmed.length),
          style: TextStyle(
            fontSize: 12,
            height: 1.45,
            fontWeight: FontWeight.bold,
            color: highlightTextColor,
            backgroundColor: highlightBgColor,
          ),
        ),
      );
      start = index + trimmed.length;
    }

    return TextSpan(children: spans);
  }

  Future<void> _toggleAudioRecording() async {
    if (_isRecordingAudio) {
      setState(() {
        _isRecordingAudio = false;
      });
      _audioClockTimer?.cancel();
      await _runGeminiAudioTranscriptionAndSummary(
        audioBytes: _lectureAudioSession.audioBytes,
        audioMimeType: _lectureAudioSession.audioMimeType,
      );
    } else {
      setState(() {
        _isPlayingAudio = false;
        _isRecordingAudio = true;
      });
      _startAudioClock();
    }
  }

  Future<void> _pickAndTranscribeExternalAudioFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['m4a', 'mp3', 'wav', 'aac'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    final bytes = picked.bytes;
    if (bytes == null) return;

    final ext = (picked.extension ?? 'm4a').toLowerCase();
    final mimeType = switch (ext) {
      'mp3' => 'audio/mpeg',
      'wav' => 'audio/wav',
      'aac' => 'audio/aac',
      _ => 'audio/mp4',
    };

    setState(() {
      _lectureAudioSession.title = picked.name;
      _lectureAudioSession.audioBytes = bytes;
      _lectureAudioSession.audioMimeType = mimeType;
    });

    await _runGeminiAudioTranscriptionAndSummary(
      audioBytes: bytes,
      audioMimeType: mimeType,
    );
  }

  Future<void> _runGeminiAudioTranscriptionAndSummary({
    Uint8List? audioBytes,
    required String audioMimeType,
  }) async {
    setState(() => _isTranscribingAudio = true);

    final String pageText = _extractedPageTexts[_currentPage] ??
        '생물학개론 제3장 세포호흡과 산화적 인산화 기출문제 ($_currentPage페이지)';

    final LectureAudioAnalysisResult analysis =
        await _geminiService.transcribeAndSummarizeLectureAudio(
      audioBytes: audioBytes,
      audioMimeType: audioMimeType,
      totalDurationMs: _lectureAudioSession.totalDurationMs,
      currentPage: _currentPage,
      currentPageText: pageText,
      recordedStrokes: _currentPageStrokes,
    );

    if (!mounted) return;

    setState(() {
      _isTranscribingAudio = false;
      _lectureAudioSession.aiLectureSummary = analysis.lectureSummary;
      _lectureAudioSession.examHighlightPoints = analysis.examHighlightPoints;
      _lectureAudioSession.segments = analysis.segments;
      _currentAiSummary = analysis.lectureSummary;

      _notebookQaHistory.insert(
        0,
        NotebookQaAnswer(
          question: '[강의 녹음 AI 자동 요약] ${_lectureAudioSession.title}',
          answer:
              '${analysis.lectureSummary}\n\n[교수님 시험 강조 포인트]\n${analysis.examHighlightPoints.map((p) => "• $p").join("\n")}',
          citedPages: analysis.segments
              .map((s) => s.pageNumber)
              .toSet()
              .toList(),
        ),
      );
    });

    await _syncRepo.saveAudioSession(_lectureAudioSession);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Gemini 강의 음성 전사 완료: 시간대별 세그먼트 ${analysis.segments.length}개와 핵심 요약이 생성되었습니다.',
        ),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: '전사 대본 검색',
          onPressed: _showAudioTranscriptSheet,
        ),
      ),
    );
  }

  /// 키워드 검색창이 탑재된 AI 전사 대본 모달 시트:
  /// 검색어 입력 시 해당 단어를 말씀하신 녹음 시점과 그때 그은 필기 획(NormalizedStroke)을 동시에 하이라이트합니다.
  void _showAudioTranscriptSheet() {
    final searchController =
        TextEditingController(text: _activeTranscriptSearchQuery);
    const presetKeywords = ['미토콘드리아', 'ΔpH', '별표', '형광펜'];

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final colorScheme = Theme.of(ctx).colorScheme;
            final currentQuery = searchController.text.trim();
            final filteredSegments = _lectureAudioSession.segments
                .where((seg) => seg.matchesKeyword(currentQuery))
                .toList();

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.72,
              maxChildSize: 0.92,
              builder: (ctx, scrollController) {
                return Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 16,
                    bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.record_voice_over_outlined,
                                color: colorScheme.primary,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'AI 전사 대본 키워드 검색 & 필기 동시 하이라이트',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              _pickAndTranscribeExternalAudioFile();
                            },
                            icon: const Icon(
                              Icons.audio_file_outlined,
                              size: 16,
                            ),
                            label: const Text(
                              '외부 녹음파일(.m4a/.mp3) 분석',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 1) 키워드 검색창 (입력 즉시 녹음 시점 + 연동된 필기 획 동시 하이라이트)
                      TextField(
                        controller: searchController,
                        onChanged: (val) {
                          _applyTranscriptKeywordSearch(
                            val,
                            jumpAudioToFirstMatch: true,
                          );
                          setSheetState(() {});
                        },
                        decoration: InputDecoration(
                          hintText:
                              '전사 대본에서 키워드 검색 (예: 미토콘드리아, ΔpH, 별표)...',
                          hintStyle: const TextStyle(fontSize: 12),
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: currentQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  tooltip: '검색어 및 하이라이트 초기화',
                                  onPressed: () {
                                    searchController.clear();
                                    _applyTranscriptKeywordSearch(
                                      '',
                                      jumpAudioToFirstMatch: false,
                                    );
                                    setSheetState(() {});
                                  },
                                )
                              : null,
                          isDense: true,
                          filled: true,
                          fillColor: colorScheme.surfaceContainerLow,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // 2) 원탭 추천 키워드 칩 + 매칭된 필기 획 개수 배지
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text(
                            '빠른 키워드:',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          ...presetKeywords.map((kw) {
                            final isSelected = currentQuery == kw;
                            return ChoiceChip(
                              label: Text(
                                kw,
                                style: const TextStyle(fontSize: 11),
                              ),
                              selected: isSelected,
                              visualDensity: VisualDensity.compact,
                              onSelected: (selected) {
                                final nextQuery = selected ? kw : '';
                                searchController.text = nextQuery;
                                _applyTranscriptKeywordSearch(
                                  nextQuery,
                                  jumpAudioToFirstMatch: true,
                                );
                                setSheetState(() {});
                              },
                            );
                          }),
                          if (currentQuery.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD81B60)
                                    .withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '검색 결과 ${filteredSegments.length}건 · 동시 하이라이트된 필기 획 ${_highlightedStrokeIds.length}개',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFD81B60),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // 2-B) 키워드 하이라이트 오디오북 플레이리스트 컨트롤 패널
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.tertiaryContainer
                              .withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colorScheme.tertiary.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.headphones_outlined,
                                  size: 16,
                                  color: colorScheme.onTertiaryContainer,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _isPlaylistModeActive &&
                                            _audiobookPlaylist.isNotEmpty
                                        ? '오디오북 재생 중: $_playlistTitle (트랙 ${_currentPlaylistTrackIndex + 1}/${_audiobookPlaylist.length})'
                                        : '키워드 하이라이트 오디오북 플레이리스트 (비매칭 공백 자동 스킵)',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onTertiaryContainer,
                                    ),
                                  ),
                                ),
                                ActionChip(
                                  label: Text(
                                    '${_playbackSpeed}x 배속',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    _cyclePlaybackSpeed();
                                    setSheetState(() {});
                                  },
                                ),
                                const SizedBox(width: 6),
                                FilterChip(
                                  label: const Text(
                                    '반복',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                  selected: _playlistLoopEnabled,
                                  visualDensity: VisualDensity.compact,
                                  onSelected: (val) {
                                    setState(() => _playlistLoopEnabled = val);
                                    setSheetState(() {});
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: filteredSegments.isEmpty
                                      ? null
                                      : () {
                                          Navigator.of(ctx).pop();
                                          _buildAndStartAudiobookPlaylist(
                                            keywordFilter: currentQuery,
                                            strokeLinkedOnly: false,
                                          );
                                        },
                                  icon: const Icon(
                                    Icons.playlist_play,
                                    size: 18,
                                  ),
                                  label: Text(
                                    currentQuery.isNotEmpty
                                        ? '"$currentQuery" 매칭 구간 연속 재생 (${filteredSegments.length}트랙)'
                                        : '전체 핵심 세그먼트 연속 재생 (${filteredSegments.length}트랙)',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: () {
                                    Navigator.of(ctx).pop();
                                    _buildAndStartAudiobookPlaylist(
                                      keywordFilter: currentQuery,
                                      strokeLinkedOnly: true,
                                    );
                                  },
                                  icon: const Icon(Icons.gesture, size: 15),
                                  label: const Text(
                                    '필기 연동 구간만 모아 듣기',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                ),
                                FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: () {
                                    Navigator.of(ctx).pop();
                                    _startVoiceClozeQuizPlaylist(
                                      keywordFilter: currentQuery,
                                    );
                                  },
                                  icon: const Icon(
                                    Icons.quiz_outlined,
                                    size: 15,
                                  ),
                                  label: const Text(
                                    '가림막 결합 음성 빈칸 퀴즈 시작',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: () {
                                    Navigator.of(ctx).pop();
                                    _generateAndShowOnePageCheatSheet(
                                      keywordFilter: currentQuery,
                                    );
                                  },
                                  icon: const Icon(
                                    Icons.auto_stories_outlined,
                                    size: 15,
                                  ),
                                  label: const Text(
                                    '시험 직전 1페이지 핵심 요약본 생성',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                ),
                                if (_audiobookPlaylist.isNotEmpty)
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    onPressed: () {
                                      _stopAudiobookPlaylist();
                                      setSheetState(() {});
                                    },
                                    icon: const Icon(
                                      Icons.stop_circle_outlined,
                                      size: 15,
                                    ),
                                    label: const Text(
                                      '플레이리스트 정지',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // 3) AI 강의 요약 박스
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'AI 강의 요약: ${_lectureAudioSession.aiLectureSummary}',
                          style: const TextStyle(fontSize: 12, height: 1.4),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // 4) 필터링된 전사 세그먼트 + 해당 시점에 그은 필기 획 배지 목록
                      Expanded(
                        child: filteredSegments.isEmpty
                            ? Center(
                                child: Text(
                                  '"$currentQuery" 키워드와 일치하는 강의 음성 전사 구간이 없습니다.',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                controller: scrollController,
                                itemCount: filteredSegments.length,
                                itemBuilder: (ctx, i) {
                                  final seg = filteredSegments[i];
                                  final linkedStrokes =
                                      _findStrokesForTranscriptSegment(seg);
                                  final isCurrentPlayhead =
                                      _currentAudioPositionMs >= seg.startMs &&
                                          _currentAudioPositionMs <= seg.endMs;
                                  final isKeywordMatched =
                                      currentQuery.isNotEmpty;

                                  return Card(
                                    elevation: 0,
                                    color: isKeywordMatched
                                        ? colorScheme.secondaryContainer
                                            .withValues(alpha: 0.7)
                                        : (isCurrentPlayhead
                                            ? colorScheme.primaryContainer
                                                .withValues(alpha: 0.5)
                                            : colorScheme.surfaceContainerLow),
                                    margin: const EdgeInsets.only(bottom: 8),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () {
                                        Navigator.of(ctx).pop();
                                        _jumpToCitedPage(seg.pageNumber);
                                        setState(() {
                                          // 해당 세그먼트의 첫 필기 획 시점 또는 세그먼트 시작점으로 점프 & 필기 획 하이라이트
                                          _currentAudioPositionMs =
                                              linkedStrokes.isNotEmpty &&
                                                      linkedStrokes.first
                                                              .audioStartMs !=
                                                          null
                                                  ? linkedStrokes
                                                      .first.audioStartMs!
                                                  : seg.startMs;
                                          _highlightedStrokeIds
                                            ..clear()
                                            ..addAll(linkedStrokes
                                                .map((s) => s.strokeId));
                                          _isPlayingAudio = true;
                                        });
                                        _startAudioClock();
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 8,
                                                    vertical: 3,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: colorScheme.primary,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8),
                                                  ),
                                                  child: Text(
                                                    seg.formattedRange,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color:
                                                          colorScheme.onPrimary,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: colorScheme.surface,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            6),
                                                  ),
                                                  child: Text(
                                                    'p.${seg.pageNumber} · ${seg.keyConceptTag}',
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                                const Spacer(),
                                                Builder(
                                                  builder: (_) {
                                                    final trackIdx =
                                                        _audiobookPlaylist
                                                            .indexWhere(
                                                      (t) =>
                                                          t.segment.startMs ==
                                                              seg.startMs &&
                                                          t.segment
                                                                  .pageNumber ==
                                                              seg.pageNumber,
                                                    );
                                                    final inQueue =
                                                        trackIdx >= 0;
                                                    return Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        InkWell(
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(8),
                                                          onTap: () {
                                                            _toggleSegmentInPlaylist(
                                                                seg);
                                                            setSheetState(
                                                                () {});
                                                          },
                                                          child: Container(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                              horizontal: 6,
                                                              vertical: 2,
                                                            ),
                                                            decoration:
                                                                BoxDecoration(
                                                              color: inQueue
                                                                  ? colorScheme
                                                                      .tertiaryContainer
                                                                  : colorScheme
                                                                      .surfaceContainerHighest,
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                          8),
                                                            ),
                                                            child: Row(
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .min,
                                                              children: [
                                                                Icon(
                                                                  inQueue
                                                                      ? Icons
                                                                          .playlist_add_check
                                                                      : Icons
                                                                          .playlist_add,
                                                                  size: 14,
                                                                  color: inQueue
                                                                      ? colorScheme
                                                                          .onTertiaryContainer
                                                                      : colorScheme
                                                                          .onSurfaceVariant,
                                                                ),
                                                                const SizedBox(
                                                                    width: 3),
                                                                Text(
                                                                  inQueue
                                                                      ? '트랙 #${trackIdx + 1}'
                                                                      : '+오디오북',
                                                                  style:
                                                                      TextStyle(
                                                                    fontSize:
                                                                        10,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w600,
                                                                    color: inQueue
                                                                        ? colorScheme
                                                                            .onTertiaryContainer
                                                                        : colorScheme
                                                                            .onSurfaceVariant,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                            width: 6),
                                                        const Icon(
                                                          Icons
                                                              .play_circle_outline,
                                                          size: 18,
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            RichText(
                                              text: _buildHighlightedTextSpan(
                                                fullText: seg.transcriptText,
                                                query: currentQuery,
                                                baseColor:
                                                    colorScheme.onSurface,
                                                highlightBgColor:
                                                    const Color(0xFFFFEE58),
                                                highlightTextColor:
                                                    Colors.black87,
                                              ),
                                            ),
                                            if (linkedStrokes.isNotEmpty) ...[
                                              const SizedBox(height: 8),
                                              Wrap(
                                                spacing: 6,
                                                runSpacing: 4,
                                                children: linkedStrokes
                                                    .map(
                                                      (s) => Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                          horizontal: 8,
                                                          vertical: 3,
                                                        ),
                                                        decoration:
                                                            BoxDecoration(
                                                          color: const Color(
                                                                  0xFFD81B60)
                                                              .withValues(
                                                                  alpha: 0.14),
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(8),
                                                          border: Border.all(
                                                            color: const Color(
                                                                0xFFD81B60),
                                                            width: 0.8,
                                                          ),
                                                        ),
                                                        child: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            const Icon(
                                                              Icons.gesture,
                                                              size: 12,
                                                              color: Color(
                                                                  0xFFD81B60),
                                                            ),
                                                            const SizedBox(
                                                                width: 4),
                                                            Text(
                                                              '동시 하이라이트된 필기: ${s.tool == DrawingTool.highlighter ? "형광펜" : "펜"} [${s.formattedTimestamp}]',
                                                              style:
                                                                  const TextStyle(
                                                                fontSize: 11,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                color: Color(
                                                                    0xFFD81B60),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    )
                                                    .toList(),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _toggleAudioPlayback() {
    setState(() {
      if (_isPlayingAudio) {
        _isPlayingAudio = false;
        _audioClockTimer?.cancel();
      } else {
        _isRecordingAudio = false;
        if (_currentAudioPositionMs >= _lectureAudioSession.totalDurationMs) {
          _currentAudioPositionMs = 0;
        }
        _isPlayingAudio = true;
        _startAudioClock();
      }
    });
  }

  void _startAudioClock() {
    _audioClockTimer?.cancel();
    _audioClockTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted) return;
      final int stepMs = _isRecordingAudio
          ? 100
          : (100 * _playbackSpeed).round().clamp(50, 400);

      setState(() {
        _currentAudioPositionMs += stepMs;
        if (_isRecordingAudio) {
          if (_currentAudioPositionMs > _lectureAudioSession.totalDurationMs) {
            _lectureAudioSession.totalDurationMs = _currentAudioPositionMs;
          }
        } else if (_isPlayingAudio) {
          // 1) 오디오북 플레이리스트 연속 재생 모드일 때:
          // 현재 트랙 종료 시점(effectiveEndMs)에 도달하면 비매칭 공백 구간을 건너뛰고 다음 트랙으로 자동 점프
          if (_isPlaylistModeActive && _audiobookPlaylist.isNotEmpty) {
            final safeIdx = _currentPlaylistTrackIndex.clamp(
              0,
              _audiobookPlaylist.length - 1,
            );
            final currentTrack = _audiobookPlaylist[safeIdx];

            // 현재 트랙에 연결된 필기 획들을 지속적으로 하이라이트 유지
            _highlightedStrokeIds
              ..clear()
              ..addAll(currentTrack.linkedStrokes.map((s) => s.strokeId));

            // [핵심] 음성 빈칸 퀴즈 모드: 교수님이 암기 가림막(Masking Tape) 정답 키워드를 말씀하시기 직전에 오디오 일시정지!
            if (_isVoiceClozeQuizMode) {
              final quizMask = currentTrack.primaryQuizMask;
              final pauseTriggerMs = currentTrack.quizPauseTriggerMs;
              if (quizMask != null &&
                  !quizMask.isRevealed &&
                  pauseTriggerMs != null &&
                  !_quizTriggeredTrackIds.contains(currentTrack.trackId) &&
                  _currentAudioPositionMs >= pauseTriggerMs) {
                _currentAudioPositionMs = pauseTriggerMs;
                _activeQuizPausedMask = quizMask;
                _quizTriggeredTrackIds.add(currentTrack.trackId);
                _isPlayingAudio = false;
                t.cancel();
                return;
              }
            }

            if (_currentAudioPositionMs >= currentTrack.effectiveEndMs) {
              final nextIdx = safeIdx + 1;
              if (nextIdx < _audiobookPlaylist.length) {
                final nextTrack = _audiobookPlaylist[nextIdx];
                _currentPlaylistTrackIndex = nextIdx;
                _currentAudioPositionMs = nextTrack.effectiveStartMs;
                _currentPage =
                    nextTrack.segment.pageNumber.clamp(1, _totalPages);
                _highlightedStrokeIds
                  ..clear()
                  ..addAll(nextTrack.linkedStrokes.map((s) => s.strokeId));
                if (_loadedPdfBytes != null) {
                  _pdfViewerController.jumpToPage(_currentPage);
                }
              } else if (_playlistLoopEnabled) {
                final firstTrack = _audiobookPlaylist.first;
                _currentPlaylistTrackIndex = 0;
                _currentAudioPositionMs = firstTrack.effectiveStartMs;
                _currentPage =
                    firstTrack.segment.pageNumber.clamp(1, _totalPages);
                _highlightedStrokeIds
                  ..clear()
                  ..addAll(firstTrack.linkedStrokes.map((s) => s.strokeId));
                if (_loadedPdfBytes != null) {
                  _pdfViewerController.jumpToPage(_currentPage);
                }
              } else {
                _currentAudioPositionMs = currentTrack.effectiveEndMs;
                _isPlayingAudio = false;
                t.cancel();
              }
              return;
            }
          }

          // 2) 일반 재생 모드일 때: 현재 재생 시점과 겹치는 필기 획 실시간 하이라이트
          final active = _currentPageStrokes.where((s) {
            if (s.audioStartMs == null) return false;
            final end = s.audioEndMs ?? (s.audioStartMs! + 2500);
            return _currentAudioPositionMs >= s.audioStartMs! &&
                _currentAudioPositionMs <= end;
          }).toList();

          if (!_isPlaylistModeActive && _activeTranscriptSearchQuery.isEmpty) {
            _highlightedStrokeIds
              ..clear()
              ..addAll(active.map((s) => s.strokeId));
          }

          if (_currentAudioPositionMs >= _lectureAudioSession.totalDurationMs) {
            _currentAudioPositionMs = _lectureAudioSession.totalDurationMs;
            _isPlayingAudio = false;
            t.cancel();
          }
        }
      });
    });
  }

  void _seekAudioToStroke(NormalizedStroke stroke) {
    final targetMs = stroke.audioStartMs;
    if (targetMs == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('이 필기 획에는 연결된 강의 녹음 타임스탬프가 없습니다.'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      _isRecordingAudio = false;
      _currentAudioPositionMs =
          targetMs.clamp(0, _lectureAudioSession.totalDurationMs);
      _highlightedStrokeIds
        ..clear()
        ..add(stroke.strokeId);
      _isPlayingAudio = true;
    });
    _startAudioClock();

    final seg = _lectureAudioSession.segmentAt(_currentAudioPositionMs);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '오디오 점프 재생 [${stroke.formattedTimestamp}]: ${seg?.transcriptText ?? "필기 시점 재생 중"}',
        ),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _formatMs(int ms) {
    final totalSec = (ms ~/ 1000).clamp(0, 359999);
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _initSyncEngine() async {
    await _syncRepo.initLocalSqlite();
    await _loadAndMergeCurrentPageFromRepo();

    _syncRepo.subscribeToDocumentRealtime(
      docId: _currentDocId,
      onRemotePageUpdated: (remoteSnap) {
        if (!mounted) return;
        final page = remoteSnap.pageNumber;
        final localSnap = PageAnnotationSnapshot(
          docId: _currentDocId,
          pageNumber: page,
          strokes: _strokesByPage[page] ?? const [],
          masks: _masksByPage[page] ?? const [],
          deletedIds: _deletedIdsByPage[page] ?? <String>{},
        );
        final merged = localSnap.mergeWith(remoteSnap);
        setState(() {
          _strokesByPage[page] = merged.strokes;
          _masksByPage[page] = merged.masks;
          _deletedIdsByPage[page] = merged.deletedIds;
          _syncState = SyncState.synced;
        });
      },
    );
  }

  Future<void> _loadAndMergeCurrentPageFromRepo() async {
    final loaded = await _syncRepo.loadAndMergePageAnnotations(
      docId: _currentDocId,
      pageNumber: _currentPage,
    );
    if (loaded != null && mounted) {
      final currentSnap = PageAnnotationSnapshot(
        docId: _currentDocId,
        pageNumber: _currentPage,
        strokes: _currentPageStrokes,
        masks: _currentPageMasks,
        deletedIds: _currentPageDeletedIds,
      );
      final merged = currentSnap.mergeWith(loaded);
      setState(() {
        _strokesByPage[_currentPage] = merged.strokes;
        _masksByPage[_currentPage] = merged.masks;
        _deletedIdsByPage[_currentPage] = merged.deletedIds;
      });
    }
  }

  Future<void> _persistCurrentPageAnnotations() async {
    setState(() => _syncState = SyncState.syncing);
    final snapshot = PageAnnotationSnapshot(
      docId: _currentDocId,
      pageNumber: _currentPage,
      strokes: List<NormalizedStroke>.from(_currentPageStrokes),
      masks: List<NormalizedMaskRect>.from(_currentPageMasks),
      deletedIds: Set<String>.from(_currentPageDeletedIds),
    );
    final onlineSuccess = await _syncRepo.savePageAnnotations(snapshot);
    if (!mounted) return;
    setState(() {
      _syncState = onlineSuccess ? SyncState.synced : SyncState.offlineQueued;
    });
  }

  Future<Uint8List?> _captureAndCropNormalizedRect(
    Rect normalizedRect,
  ) async {
    try {
      final boundaryContext = _pdfPageBoundaryKey.currentContext;
      if (boundaryContext == null) return null;

      final boundary =
          boundaryContext.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;

      const double pixelRatio = 2.0;
      final ui.Image fullPageImage =
          await boundary.toImage(pixelRatio: pixelRatio);

      final double srcLeft = (normalizedRect.left * fullPageImage.width)
          .clamp(0.0, fullPageImage.width.toDouble());
      final double srcTop = (normalizedRect.top * fullPageImage.height)
          .clamp(0.0, fullPageImage.height.toDouble());
      final double srcWidth = (normalizedRect.width * fullPageImage.width)
          .clamp(1.0, fullPageImage.width - srcLeft);
      final double srcHeight = (normalizedRect.height * fullPageImage.height)
          .clamp(1.0, fullPageImage.height - srcTop);

      final Rect srcRect = Rect.fromLTWH(srcLeft, srcTop, srcWidth, srcHeight);
      final Rect dstRect = Rect.fromLTWH(0, 0, srcWidth, srcHeight);

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas cropCanvas = Canvas(recorder, dstRect);
      cropCanvas.drawImageRect(fullPageImage, srcRect, dstRect, Paint());

      final ui.Picture picture = recorder.endRecording();
      final ui.Image croppedImage = await picture.toImage(
        srcWidth.round(),
        srcHeight.round(),
      );
      final ByteData? byteData = await croppedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      fullPageImage.dispose();
      croppedImage.dispose();

      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('올가미 영역 이미지 캡처 실패: $e');
      return null;
    }
  }

  Future<void> _processAiLassoSelection(Rect normalizedRect) async {
    setState(() => _isAnalyzingLasso = true);

    final Uint8List? croppedBytes =
        await _captureAndCropNormalizedRect(normalizedRect);

    _sidebarTabController.animateTo(1);

    final String pageContext = _extractedPageTexts[_currentPage] ??
        '생물학개론 제3장 세포호흡과 산화적 인산화 기출문제 ($_currentPage페이지)';

    final WrongAnswerStudyCard generatedCard =
        await _geminiService.analyzeLassoCropAndGenerateTwinQuestion(
      docId: _currentDocId,
      pageNumber: _currentPage,
      normalizedCropRect: normalizedRect,
      croppedPngBytes: croppedBytes,
      pageTextContext: pageContext,
    );

    await _syncRepo.saveStudyCard(generatedCard);

    if (!mounted) return;
    setState(() {
      _isAnalyzingLasso = false;
      _studyCards.insert(0, generatedCard);
      // 플렉슬 스타일 단권화 서브노트에도 캡처 이미지와 출처 페이지 링크를 자동 스크랩!
      _subNoteScrapClips.insert(
        0,
        SubNoteScrapClip(
          clipId: 'clip_${DateTime.now().millisecondsSinceEpoch}',
          sourcePageNumber: _currentPage,
          sourceNormalizedRect: normalizedRect,
          croppedImageBytes: croppedBytes,
          extractedSnippetText: generatedCard.recognizedQuestion,
          userAnnotationMemo: generatedCard.twinAnswer,
          linkedAudioMs: _currentAudioPositionMs,
        ),
      );
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'AI 올가미 분석 완료: p.$_currentPage 문제 해설과 유사 변형 문제가 오답 탭에 추가되었습니다.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _showFlattenExportDialog() async {
    MaskExportMode selectedMaskMode = MaskExportMode.revealWithHighlight;
    bool appendAiAppendix = true;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.picture_as_pdf_outlined, size: 22),
                  SizedBox(width: 8),
                  Text('필기 + AI 요약 합본 PDF 내보내기', style: TextStyle(fontSize: 16)),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '1. 암기 가림막(Masking Tape) 처리 방식',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    RadioListTile<MaskExportMode>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('단권화 복습 모드 (반투명 하이라이트 + 본문 표시)'),
                      subtitle: const Text('형광펜처럼 아래 정답이 비치도록 합쳐서 내보냅니다.'),
                      value: MaskExportMode.revealWithHighlight,
                      groupValue: selectedMaskMode,
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => selectedMaskMode = val);
                        }
                      },
                    ),
                    RadioListTile<MaskExportMode>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('백지 테스트 시험지 모드 (정답 불투명 마스킹)'),
                      subtitle: const Text('인쇄해서 빈칸 채우기 시험을 볼 수 있도록 정답을 가립니다.'),
                      value: MaskExportMode.blindForSelfTest,
                      groupValue: selectedMaskMode,
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => selectedMaskMode = val);
                        }
                      },
                    ),
                    const Divider(height: 20),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '마지막 페이지에 Gemini 요약·교차 핀·서브노트·정돈 비교표 부록 추가',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '강의 전사·유사 문제(부록 I) 및 듀얼 PDF 교차 핀(${_crossDocPins.length}개), 단권화 스크랩(${_subNoteScrapClips.length}개), 인쇄체 정돈 비교표(${_cleanTypesetBlocksByPage.values.expand((e) => e).length}개)를 부록 II 페이지로 함께 렌더링합니다.',
                        style: const TextStyle(fontSize: 11),
                      ),
                      value: appendAiAppendix,
                      onChanged: (val) =>
                          setDialogState(() => appendAiAppendix = val),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('취소'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  icon: const Icon(Icons.download, size: 17),
                  label: const Text('PDF 병합 및 저장'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isExportingPdf = true);

    try {
      final Uint8List flattenedBytes =
          await _exportService.flattenAndExportPdf(
        originalPdfBytes: _loadedPdfBytes,
        documentTitle: _currentFileName,
        subjectFolder: _currentSubjectFolder,
        subTopic: _currentSubTopic,
        docType: _currentDocType,
        examDdayLabel: _examDdayLabel,
        aiSummary: _currentAiSummary,
        strokesByPage: _strokesByPage,
        masksByPage: _masksByPage,
        notebookQaList: _notebookQaHistory,
        studyCards: _studyCards,
        audioSession: _lectureAudioSession,
        maskMode: selectedMaskMode,
        appendAiSummaryPage: appendAiAppendix,
        crossDocPins: _crossDocPins,
        subNoteScrapClips: _subNoteScrapClips,
        cleanTypesetBlocksByPage: _cleanTypesetBlocksByPage,
      );

      final String? savedLocation =
          await _exportService.saveFlattenedPdfToDevice(
        flattenedPdfBytes: flattenedBytes,
        originalFileName: _currentFileName,
        maskMode: selectedMaskMode,
      );

      if (!mounted) return;
      setState(() => _isExportingPdf = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedLocation != null
                ? '필기·요약 합본 PDF 저장 완료: $savedLocation'
                : '필기·요약 합본 PDF 생성이 완료되었습니다.',
          ),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: '뷰어에서 합본 미리보기',
            onPressed: () {
              setState(() {
                _loadedPdfBytes = flattenedBytes;
              });
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isExportingPdf = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('PDF 병합 내보내기 중 오류가 발생했습니다: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    _pomodoroTimer?.cancel();
    _audioClockTimer?.cancel();
    _coStudyPeerSimTimer?.cancel();
    _shapeSnapHoldTimer?.cancel();
    _sidebarTabController.dispose();
    _pdfViewerController.dispose();
    _secondaryPdfController.dispose();
    _questionController.dispose();
    _syncRepo.dispose();
    super.dispose();
  }

  Future<void> _pickAndClassifyPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;
    final pickedFile = result.files.single;
    final bytes = pickedFile.bytes;
    if (bytes == null) return;

    final newDocId = 'doc_${pickedFile.name.hashCode.abs()}';

    setState(() {
      _loadedPdfBytes = bytes;
      _currentDocId = newDocId;
      _currentFileName = pickedFile.name;
      _currentPage = 1;
      _isClassifyingPdf = true;
    });

    String firstThreePagesText = '';
    try {
      final document = sf_pdf.PdfDocument(inputBytes: bytes);
      final pageCount = document.pages.count;
      final extractor = sf_pdf.PdfTextExtractor(document);

      _extractedPageTexts.clear();
      final maxIndexPages = math.min(pageCount, 50);
      for (int i = 0; i < maxIndexPages; i++) {
        final pageText = extractor.extractText(
          startPageIndex: i,
          endPageIndex: i,
        );
        _extractedPageTexts[i + 1] = pageText;
        if (i < 3) {
          firstThreePagesText += '\n[Page ${i + 1}]\n$pageText';
        }
      }
      document.dispose();

      setState(() {
        _totalPages = pageCount;
      });
    } catch (e) {
      debugPrint('PDF 텍스트 추출 중 오류: $e');
    }

    final classification = await _geminiService.classifyPdfDocument(
      fileName: pickedFile.name,
      extractedPreviewText: firstThreePagesText,
      rawPdfBytes: bytes,
    );

    if (!mounted) return;

    AutoFolderItem targetFolder;
    final existingIdx = _folders.indexWhere(
      (f) => f.subjectName == classification.subjectFolder,
    );
    if (existingIdx >= 0) {
      _folders[existingIdx].docCount++;
      targetFolder = _folders[existingIdx];
    } else {
      targetFolder = AutoFolderItem(
        id: 'folder_${classification.subjectFolder.hashCode.abs()}',
        subjectName: classification.subjectFolder,
        subTopicSummary: '${classification.subTopic} (문서 1개)',
        docTypeBadge: classification.docType,
        keywords: classification.keywords,
        docCount: 1,
      );
      _folders.insert(0, targetFolder);
    }

    setState(() {
      _isClassifyingPdf = false;
      _currentSubjectFolder = classification.subjectFolder;
      _currentSubTopic = classification.subTopic;
      _currentDocType = classification.docType;
      _currentAiSummary = classification.summary;

      if (classification.extractedExamDate != null &&
          classification.extractedExamDate!.isNotEmpty) {
        final parsed = DateTime.tryParse(classification.extractedExamDate!);
        if (parsed != null) {
          final diffDays = parsed.difference(DateTime.now()).inDays;
          _examDdayLabel = diffDays >= 0
              ? '${classification.subjectFolder} 시험 D-$diffDays'
              : '${classification.extractedExamDate} 시험';
        }
      }
    });

    setState(() => _syncState = SyncState.syncing);
    final synced = await _syncRepo.saveFolderAndClassifiedDocument(
      folder: targetFolder,
      docId: _currentDocId,
      fileName: _currentFileName,
      classification: classification,
      readCount: _readCount,
      pdfBytes: bytes,
    );
    _syncRepo.subscribeToDocumentRealtime(
      docId: _currentDocId,
      onRemotePageUpdated: (remoteSnap) {
        if (!mounted) return;
        setState(() {
          _strokesByPage[remoteSnap.pageNumber] = remoteSnap.strokes;
          _masksByPage[remoteSnap.pageNumber] = remoteSnap.masks;
          _deletedIdsByPage[remoteSnap.pageNumber] = remoteSnap.deletedIds;
          _syncState = SyncState.synced;
        });
      },
    );

    if (!mounted) return;
    setState(() {
      _syncState = synced ? SyncState.synced : SyncState.offlineQueued;
    });
  }

  Future<void> _submitNotebookQuestion() async {
    final q = _questionController.text.trim();
    if (q.isEmpty || _isAskingNotebook) return;

    _questionController.clear();
    setState(() => _isAskingNotebook = true);

    final qaResult = await _geminiService.askNotebookWithCitations(
      question: q,
      pageTexts: _extractedPageTexts,
    );

    if (!mounted) return;
    setState(() {
      _isAskingNotebook = false;
      _notebookQaHistory.insert(0, qaResult);
    });
  }

  void _jumpToCitedPage(int pageNumber) {
    final target = pageNumber.clamp(1, _totalPages);
    setState(() {
      _currentPage = target;
    });
    if (_loadedPdfBytes != null) {
      _pdfViewerController.jumpToPage(target);
    }
    _loadAndMergeCurrentPageFromRepo();
  }

  void _togglePomodoro() {
    setState(() {
      _isTimerRunning = !_isTimerRunning;
    });
    if (_isTimerRunning) {
      _pomodoroTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_remainingSeconds > 0) {
          setState(() => _remainingSeconds--);
        } else {
          timer.cancel();
          setState(() => _isTimerRunning = false);
        }
      });
    } else {
      _pomodoroTimer?.cancel();
    }
  }

  String get _formattedTimer {
    final m = (_remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final (double simW, double simH) = switch (_simulatedViewportPreset) {
          'ipad_4_3' => (1024.0, 768.0),
          'android_16_10' => (1280.0, 800.0),
          'split_50_50' => (640.0, 800.0),
          _ => (constraints.maxWidth, constraints.maxHeight),
        };

        final policy = TabletLayoutPolicy(
          width: simW,
          height: simH,
          isExamFocusMode: _isExamFocusMode,
          isLeftHanded: _isLeftHanded,
        );

        final folderPane = _buildAutoClassifiedFolderPane(context);
        final pdfCanvasPane = _buildPdfCanvasZone(context, policy);
        final sidebarPane = _buildGeminiNotebookAndTimerSidebar(context);

        final List<Widget> workspaceChildren = [];

        if (policy.showPersistentFolderPane && !_isLeftHanded) {
          workspaceChildren.add(
            Expanded(flex: policy.folderFlex, child: folderPane),
          );
          workspaceChildren.add(const VerticalDivider(width: 1));
        }

        if (_isLeftHanded) {
          workspaceChildren.add(
            Expanded(flex: policy.sidebarFlex, child: sidebarPane),
          );
          workspaceChildren.add(const VerticalDivider(width: 1));
          workspaceChildren.add(
            Expanded(flex: policy.canvasFlex, child: pdfCanvasPane),
          );
          if (policy.showPersistentFolderPane) {
            workspaceChildren.add(const VerticalDivider(width: 1));
            workspaceChildren.add(
              Expanded(flex: policy.folderFlex, child: folderPane),
            );
          }
        } else {
          workspaceChildren.add(
            Expanded(flex: policy.canvasFlex, child: pdfCanvasPane),
          );
          workspaceChildren.add(const VerticalDivider(width: 1));
          workspaceChildren.add(
            Expanded(flex: policy.sidebarFlex, child: sidebarPane),
          );
        }

        return Scaffold(
          key: _scaffoldKey,
          drawer: policy.showPersistentFolderPane
              ? null
              : Drawer(width: 310, child: folderPane),
          body: SafeArea(
            child: Column(
              children: [
                _buildSlimTopHudBar(context, policy),
                if (_isClassifyingPdf ||
                    _isExportingPdf ||
                    _isAnalyzingLasso ||
                    _isTranscribingAudio)
                  const LinearProgressIndicator(minHeight: 3),
                const Divider(height: 1),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: workspaceChildren,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSlimTopHudBar(BuildContext context, TabletLayoutPolicy policy) {
    final colorScheme = Theme.of(context).colorScheme;

    final (syncIcon, syncLabel) = switch (_syncState) {
      SyncState.synced => (Icons.cloud_done_outlined, '실시간 동기화됨'),
      SyncState.syncing => (Icons.sync, '동기화 중...'),
      SyncState.offlineQueued => (Icons.cloud_off, '오프라인 SQLite 저장됨'),
    };

    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: policy.width - 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!policy.showPersistentFolderPane)
                    IconButton(
                      icon: const Icon(Icons.folder_copy_outlined, size: 20),
                      tooltip: '자동 분류 폴더 열기',
                      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                    ),
                  FilledButton.icon(
                    onPressed: _isClassifyingPdf ? null : _pickAndClassifyPdf,
                    icon: const Icon(Icons.upload_file, size: 17),
                    label: Text(
                      _isClassifyingPdf ? 'AI 분류 중...' : 'PDF 불러오기',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    onPressed: _isExportingPdf ? null : _showFlattenExportDialog,
                    icon: const Icon(Icons.ios_share, size: 16),
                    label: Text(
                      _isExportingPdf ? '병합 중...' : 'PDF 합본 저장',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 15,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$_currentSubjectFolder > $_currentSubTopic ($_currentDocType · p.$_currentPage/$_totalPages)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: Icon(syncIcon, size: 15),
                    label: Text(
                      syncLabel,
                      style: const TextStyle(fontSize: 11),
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      await _syncRepo.flushOfflineOutbox();
                      await _persistCurrentPageAnnotations();
                    },
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _showAiStudyPlannerModal,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.calendar_month_outlined,
                            size: 14,
                            color: colorScheme.onTertiaryContainer,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$_examDdayLabel · $_readCount/$_targetReadCount회독 (AI 플래너)',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _togglePomodoro,
                    icon: Icon(
                      _isTimerRunning ? Icons.pause_circle : Icons.play_circle,
                      size: 18,
                    ),
                    label: Text(
                      _formattedTimer,
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: const Text('시험 집중', style: TextStyle(fontSize: 12)),
                    selected: _isExamFocusMode,
                    onSelected: (val) => setState(() => _isExamFocusMode = val),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    avatar: const Icon(Icons.back_hand_outlined, size: 16),
                    label: const Text('왼손 모드', style: TextStyle(fontSize: 12)),
                    selected: _isLeftHanded,
                    onSelected: (val) => setState(() => _isLeftHanded = val),
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    avatar: const Icon(Icons.bolt, size: 15),
                    label: const Text(
                      '타임어택 모의고사',
                      style: TextStyle(fontSize: 11),
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: _startDdayTimeAttackMockExamModal,
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    avatar: const Icon(Icons.insights, size: 15),
                    label: const Text(
                      '학습 통계·백업',
                      style: TextStyle(fontSize: 11),
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: _showStudyAnalyticsDashboardModal,
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    avatar: const Icon(Icons.groups_outlined, size: 15),
                    label: Text(
                      _isCoStudyRoomActive
                          ? '스터디룸 (${_coStudyPeers.length + 1}명 동시필기)'
                          : '라이브 스터디룸',
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: _isCoStudyRoomActive,
                    visualDensity: VisualDensity.compact,
                    onSelected: _toggleCoStudyRoom,
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    avatar: const Icon(Icons.account_tree_outlined, size: 15),
                    label: const Text(
                      '메커니즘 마인드맵',
                      style: TextStyle(fontSize: 11),
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: _showMechanismMindMapModal,
                  ),
                  const SizedBox(width: 6),
                  PopupMenuButton<String>(
                    tooltip: 'iPad 4:3 / 안드로이드 16:10 / Split View 화면비 시뮬레이션',
                    initialValue: _simulatedViewportPreset,
                    onSelected: (val) =>
                        setState(() => _simulatedViewportPreset = val),
                    itemBuilder: (ctx) => const [
                      PopupMenuItem(
                        value: 'auto',
                        child: Text('자동 감지 (실제 창 크기)'),
                      ),
                      PopupMenuItem(
                        value: 'ipad_4_3',
                        child: Text('iPad 4:3 표준 2단 (68:32)'),
                      ),
                      PopupMenuItem(
                        value: 'android_16_10',
                        child: Text('Android 16:10 와이드 3단 (18:54:28)'),
                      ),
                      PopupMenuItem(
                        value: 'split_50_50',
                        child: Text('iPad Split View 멀티태스킹 (컴팩트 2단)'),
                      ),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.aspect_ratio, size: 15),
                      label: Text(
                        policy.layoutBadgeLabel,
                        style: const TextStyle(fontSize: 11),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '다크 모드 / 라이트 모드 전환',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Theme.of(context).brightness == Brightness.dark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                      size: 18,
                    ),
                    onPressed: () {
                      studyAppThemeModeNotifier.value =
                          studyAppThemeModeNotifier.value == ThemeMode.dark
                              ? ThemeMode.light
                              : ThemeMode.dark;
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutoClassifiedFolderPane(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: colorScheme.surface,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_special, size: 18, color: colorScheme.primary),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'AI 자동 분류 폴더',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 18),
                tooltip: '새 PDF 불러와서 자동 분류하기',
                onPressed: _pickAndClassifyPdf,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: _folders.length,
              itemBuilder: (context, index) {
                final f = _folders[index];
                final isSelected = f.subjectName == _currentSubjectFolder;
                return _buildFolderTile(
                  title: f.subjectName,
                  subtitle: '${f.subTopicSummary} · 총 ${f.docCount}개',
                  tag: f.docTypeBadge,
                  isSelected: isSelected,
                  onTap: () {
                    setState(() {
                      _currentSubjectFolder = f.subjectName;
                    });
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Gemini AI 자동 요약',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  _currentAiSummary,
                  style: const TextStyle(fontSize: 11, height: 1.4),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderTile({
    required String title,
    required String subtitle,
    required String tag,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: isSelected
          ? colorScheme.primaryContainer.withValues(alpha: 0.55)
          : colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        dense: true,
        onTap: onTap,
        title: Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(tag, style: const TextStyle(fontSize: 11)),
        ),
      ),
    );
  }

  Widget _buildPdfCanvasZone(BuildContext context, TabletLayoutPolicy policy) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDrawingActive = _selectedTool != DrawingTool.panScroll;

    return Container(
      color: colorScheme.surfaceContainerLowest,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 64, 12, 12),
                          child: AspectRatio(
                            aspectRatio: 1 / 1.414,
                      child: LayoutBuilder(
                        builder: (context, pageConstraints) {
                          final pageSize = Size(
                            pageConstraints.maxWidth,
                            pageConstraints.maxHeight,
                          );
                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: RepaintBoundary(
                                key: _pdfPageBoundaryKey,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (_loadedPdfBytes != null)
                                      SfPdfViewer.memory(
                                        _loadedPdfBytes!,
                                        controller: _pdfViewerController,
                                        pageLayoutMode:
                                            PdfPageLayoutMode.single,
                                        canShowScrollHead: false,
                                        onDocumentLoaded: (details) {
                                          setState(() {
                                            _totalPages =
                                                details.document.pages.count;
                                          });
                                        },
                                        onPageChanged: (details) {
                                          setState(() {
                                            _currentPage =
                                                details.newPageNumber;
                                            if (_currentPage == _totalPages &&
                                                _readCount < _targetReadCount) {
                                              _readCount++;
                                            }
                                          });
                                          _loadAndMergeCurrentPageFromRepo();
                                        },
                                      )
                                    else
                                      _buildSimulatedPdfPageContent(),

                                    IgnorePointer(
                                      ignoring: !isDrawingActive,
                                      child: Listener(
                                        behavior: HitTestBehavior.opaque,
                                        onPointerDown: (event) =>
                                            _handlePointerDown(event, pageSize),
                                        onPointerMove: (event) =>
                                            _handlePointerMove(event, pageSize),
                                        onPointerUp: (event) =>
                                            _handlePointerUp(event, pageSize),
                                        child: CustomPaint(
                                          painter: NormalizedAnnotationPainter(
                                            strokes: _currentPageStrokes,
                                            activeStroke: _activeStroke,
                                            maskPreviewStart:
                                                _maskDragStartNormalized,
                                            maskPreviewEnd:
                                                _maskDragCurrentNormalized,
                                            lassoPreviewStart:
                                                _lassoDragStartNormalized,
                                            lassoPreviewEnd:
                                                _lassoDragCurrentNormalized,
                                            currentAudioPositionMs:
                                                _currentAudioPositionMs,
                                            enableAudioReplayFilter:
                                                _enableAudioReplayFilter &&
                                                    (_isPlayingAudio ||
                                                        _selectedTool ==
                                                            DrawingTool
                                                                .audioSeek),
                                            highlightedStrokeIds:
                                                _highlightedStrokeIds,
                                          ),
                                        ),
                                      ),
                                    ),

                                    ..._currentPageStrokes
                                        .where((s) =>
                                            s.hasAudioTimestamp &&
                                            s.points.isNotEmpty)
                                        .map((stroke) {
                                      final firstPt = stroke.points.first
                                          .toPixelOffset(pageSize);
                                      final isHighlighted =
                                          _highlightedStrokeIds
                                              .contains(stroke.strokeId);
                                      return Positioned(
                                        left: (firstPt.dx - 4)
                                            .clamp(4.0, pageSize.width - 90),
                                        top: (firstPt.dy - 22)
                                            .clamp(4.0, pageSize.height - 24),
                                        child: GestureDetector(
                                          onTap: () =>
                                              _seekAudioToStroke(stroke),
                                          child: AnimatedContainer(
                                            duration: const Duration(
                                              milliseconds: 180,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isHighlighted
                                                  ? const Color(0xFFD81B60)
                                                  : const Color(0xDD1565C0),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  isHighlighted
                                                      ? Icons.auto_awesome
                                                      : Icons.volume_up,
                                                  size: 10,
                                                  color: Colors.white,
                                                ),
                                                const SizedBox(width: 3),
                                                Text(
                                                  isHighlighted &&
                                                          _activeTranscriptSearchQuery
                                                              .isNotEmpty
                                                      ? '${stroke.formattedTimestamp} ($_activeTranscriptSearchQuery)'
                                                      : stroke
                                                          .formattedTimestamp,
                                                  style: const TextStyle(
                                                    fontSize: 10,
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    }),

                                    ..._currentPageMasks.map((mask) {
                                      final rect = mask.toPixelRect(pageSize);
                                      final isQuizPausedTarget =
                                          _activeQuizPausedMask?.maskId ==
                                              mask.maskId;
                                      final useHandwritingPad =
                                          !mask.isRevealed &&
                                              (_isHandwritingGradingMode ||
                                                  isQuizPausedTarget);

                                      return Positioned(
                                        left: rect.left,
                                        top: rect.top,
                                        width: math.max(rect.width, 170),
                                        height: math.max(rect.height, 44),
                                        child: useHandwritingPad
                                            ? Container(
                                                decoration: BoxDecoration(
                                                  color: isQuizPausedTarget
                                                      ? const Color(0xFFFFF8E1)
                                                      : const Color(0xFFF3F7FF),
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  border: Border.all(
                                                    color: isQuizPausedTarget
                                                        ? const Color(
                                                            0xFFD81B60)
                                                        : const Color(
                                                            0xFF2575FC),
                                                    width: isQuizPausedTarget
                                                        ? 2.2
                                                        : 1.6,
                                                  ),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.black
                                                          .withValues(
                                                              alpha: 0.08),
                                                      blurRadius: 4,
                                                      offset:
                                                          const Offset(0, 2),
                                                    ),
                                                  ],
                                                ),
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    if (!mask.hasHandwrittenInk)
                                                      Center(
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                            horizontal: 6,
                                                          ),
                                                          child: Text(
                                                            isQuizPausedTarget
                                                                ? '✍️ [음성퀴즈] 펜슬로 정답 필기 후 [AI채점]'
                                                                : '✍️ 가림막 위에 펜슬로 정답 필기 후 [AI채점]',
                                                            style: TextStyle(
                                                              fontSize: 10,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              color: isQuizPausedTarget
                                                                  ? const Color(
                                                                      0xFFD81B60)
                                                                  : const Color(
                                                                      0xFF1565C0)
                                                                      .withValues(
                                                                          alpha:
                                                                              0.65),
                                                            ),
                                                            textAlign: TextAlign
                                                                .center,
                                                          ),
                                                        ),
                                                      ),
                                                    // 애플펜슬 / 갤럭시 S펜 / 터치 손글씨 입력 레이어
                                                    Listener(
                                                      behavior: HitTestBehavior
                                                          .opaque,
                                                      onPointerDown: (evt) {
                                                        final boxW = math.max(
                                                            rect.width, 170.0);
                                                        final boxH = math.max(
                                                            rect.height, 44.0);
                                                        final nx = (evt
                                                                    .localPosition
                                                                    .dx /
                                                                boxW)
                                                            .clamp(0.0, 1.0);
                                                        final ny = (evt
                                                                    .localPosition
                                                                    .dy /
                                                                boxH)
                                                            .clamp(0.0, 1.0);
                                                        setState(() {
                                                          mask.handwrittenInkStrokes
                                                              .add([
                                                            Offset(nx, ny),
                                                          ]);
                                                        });
                                                      },
                                                      onPointerMove: (evt) {
                                                        if (mask
                                                            .handwrittenInkStrokes
                                                            .isEmpty) {
                                                          return;
                                                        }
                                                        final boxW = math.max(
                                                            rect.width, 170.0);
                                                        final boxH = math.max(
                                                            rect.height, 44.0);
                                                        final nx = (evt
                                                                    .localPosition
                                                                    .dx /
                                                                boxW)
                                                            .clamp(0.0, 1.0);
                                                        final ny = (evt
                                                                    .localPosition
                                                                    .dy /
                                                                boxH)
                                                            .clamp(0.0, 1.0);
                                                        setState(() {
                                                          mask.handwrittenInkStrokes
                                                              .last
                                                              .add(
                                                            Offset(nx, ny),
                                                          );
                                                        });
                                                      },
                                                      child: CustomPaint(
                                                        painter:
                                                            MaskHandwritingPainter(
                                                          strokes: mask
                                                              .handwrittenInkStrokes,
                                                        ),
                                                      ),
                                                    ),
                                                    // 우측 상단 컨트롤 미니 버튼 (지우기 / AI 채점 / 바로 개봉)
                                                    Positioned(
                                                      right: 3,
                                                      bottom: 2,
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          if (mask
                                                              .hasHandwrittenInk) ...[
                                                            InkWell(
                                                              onTap: () {
                                                                setState(() {
                                                                  mask.clearHandwriting();
                                                                });
                                                              },
                                                              child: Container(
                                                                padding:
                                                                    const EdgeInsets
                                                                        .symmetric(
                                                                  horizontal: 5,
                                                                  vertical: 2,
                                                                ),
                                                                decoration:
                                                                    BoxDecoration(
                                                                  color: Colors
                                                                      .grey
                                                                      .shade200,
                                                                  borderRadius:
                                                                      BorderRadius
                                                                          .circular(
                                                                              4),
                                                                ),
                                                                child:
                                                                    const Text(
                                                                  '지우기',
                                                                  style: TextStyle(
                                                                    fontSize: 9,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .bold,
                                                                    color: Colors
                                                                        .black87,
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                                width: 3),
                                                            InkWell(
                                                              onTap: mask
                                                                      .isGradingInProgress
                                                                  ? null
                                                                  : () => _gradeMaskHandwritingWithGemini(
                                                                      mask),
                                                              child: Container(
                                                                padding:
                                                                    const EdgeInsets
                                                                        .symmetric(
                                                                  horizontal: 6,
                                                                  vertical: 2,
                                                                ),
                                                                decoration:
                                                                    BoxDecoration(
                                                                  color: const Color(
                                                                      0xFF1565C0),
                                                                  borderRadius:
                                                                      BorderRadius
                                                                          .circular(
                                                                              4),
                                                                ),
                                                                child: Text(
                                                                  mask.isGradingInProgress
                                                                      ? '채점중...'
                                                                      : 'AI채점',
                                                                  style:
                                                                      const TextStyle(
                                                                    fontSize: 9,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .bold,
                                                                    color: Colors
                                                                        .white,
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                                width: 3),
                                                          ],
                                                          InkWell(
                                                            onTap: () {
                                                              if (isQuizPausedTarget) {
                                                                _revealQuizMaskAndResumeAudio(
                                                                    mask);
                                                              } else {
                                                                setState(() {
                                                                  mask.isRevealed =
                                                                      true;
                                                                });
                                                                _persistCurrentPageAnnotations();
                                                              }
                                                            },
                                                            child: Container(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .symmetric(
                                                                horizontal: 5,
                                                                vertical: 2,
                                                              ),
                                                              decoration:
                                                                  BoxDecoration(
                                                                color: Colors
                                                                    .black
                                                                    .withValues(
                                                                        alpha:
                                                                            0.08),
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            4),
                                                              ),
                                                              child: const Text(
                                                                '개봉',
                                                                style:
                                                                    TextStyle(
                                                                  fontSize: 9,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  color: Colors
                                                                      .black87,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              )
                                            : GestureDetector(
                                                onTap: () {
                                                  if (isQuizPausedTarget &&
                                                      !mask.isRevealed) {
                                                    _revealQuizMaskAndResumeAudio(
                                                        mask);
                                                    return;
                                                  }
                                                  setState(() {
                                                    mask.isRevealed =
                                                        !mask.isRevealed;
                                                  });
                                                  _persistCurrentPageAnnotations();
                                                },
                                                child: AnimatedContainer(
                                                  duration: const Duration(
                                                    milliseconds: 180,
                                                  ),
                                                  alignment: Alignment.center,
                                                  padding: const EdgeInsets
                                                      .symmetric(horizontal: 6),
                                                  decoration: BoxDecoration(
                                                    color: mask.isRevealed
                                                        ? (mask.lastGradeResult
                                                                    ?.isCorrect ==
                                                                true
                                                            ? const Color(
                                                                    0xFF2E7D32)
                                                                .withValues(
                                                                    alpha: 0.16)
                                                            : const Color(
                                                                    0xFF2575FC)
                                                                .withValues(
                                                                    alpha:
                                                                        0.16))
                                                        : (isQuizPausedTarget
                                                            ? const Color(
                                                                0xFFD81B60)
                                                            : const Color(
                                                                0xFF2575FC)),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            6),
                                                    border: Border.all(
                                                      color: mask.isRevealed &&
                                                              mask.lastGradeResult
                                                                      ?.isCorrect ==
                                                                  true
                                                          ? const Color(
                                                              0xFF2E7D32)
                                                          : (isQuizPausedTarget
                                                              ? const Color(
                                                                  0xFFFFEE58)
                                                              : const Color(
                                                                  0xFF2575FC)),
                                                      width: isQuizPausedTarget
                                                          ? 2.5
                                                          : 1.5,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    mask.isRevealed
                                                        ? (mask.lastGradeResult !=
                                                                null
                                                            ? '✅ ${mask.hintKeyword} (${mask.lastGradeResult!.score}점)'
                                                            : mask.hintKeyword)
                                                        : '탭하여 정답 확인 (가림막)',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: mask.isRevealed
                                                          ? (mask.lastGradeResult
                                                                      ?.isCorrect ==
                                                                  true
                                                              ? const Color(
                                                                  0xFF1B5E20)
                                                              : const Color(
                                                                  0xFF0D47A1))
                                                          : Colors.white,
                                                    ),
                                                    textAlign: TextAlign.center,
                                                  ),
                                                ),
                                              ),
                                      );
                                    }),

                                    // 칠판 판서 사진 스티커 노트 오버레이 (드래그 이동 & 오디오 타임스탬프 점프)
                                    ..._currentPageBoardStickers.map((sticker) {
                                      final left = (sticker.normalizedPosition.dx *
                                              pageSize.width)
                                          .clamp(8.0, pageSize.width - 210);
                                      final top = (sticker.normalizedPosition.dy *
                                              pageSize.height)
                                          .clamp(8.0, pageSize.height - 130);
                                      return Positioned(
                                        left: left,
                                        top: top,
                                        width: sticker.isExpanded ? 202 : 128,
                                        child: GestureDetector(
                                          onPanUpdate: (details) {
                                            setState(() {
                                              final nx = ((left +
                                                          details.delta.dx) /
                                                      pageSize.width)
                                                  .clamp(0.02, 0.78);
                                              final ny = ((top +
                                                          details.delta.dy) /
                                                      pageSize.height)
                                                  .clamp(0.02, 0.85);
                                              sticker.normalizedPosition =
                                                  Offset(nx, ny);
                                            });
                                          },
                                          child: Material(
                                            elevation: 3,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            color: const Color(0xFFFFF9C4),
                                            child: Padding(
                                              padding: const EdgeInsets.all(8),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Row(
                                                    children: [
                                                      const Icon(
                                                        Icons.photo_camera_back,
                                                        size: 13,
                                                        color:
                                                            Color(0xFFE65100),
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Expanded(
                                                        child: InkWell(
                                                          onTap: () {
                                                            setState(() {
                                                              _currentAudioPositionMs =
                                                                  sticker
                                                                      .audioTimestampMs;
                                                              _isPlayingAudio =
                                                                  true;
                                                            });
                                                            _startAudioClock();
                                                          },
                                                          child: Text(
                                                            '칠판 판서 [${sticker.formattedTimestamp}]',
                                                            style:
                                                                const TextStyle(
                                                              fontSize: 10,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                              color: Color(
                                                                  0xFFE65100),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      InkWell(
                                                        onTap: () {
                                                          setState(() {
                                                            sticker.isExpanded =
                                                                !sticker
                                                                    .isExpanded;
                                                          });
                                                        },
                                                        child: Icon(
                                                          sticker.isExpanded
                                                              ? Icons
                                                                  .unfold_less
                                                              : Icons
                                                                  .unfold_more,
                                                          size: 14,
                                                          color: Colors.black54,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  if (sticker.isExpanded) ...[
                                                    const SizedBox(height: 4),
                                                    if (sticker.photoBytes !=
                                                        null)
                                                      ClipRRect(
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(6),
                                                        child: Image.memory(
                                                          sticker.photoBytes!,
                                                          height: 54,
                                                          width:
                                                              double.infinity,
                                                          fit: BoxFit.cover,
                                                        ),
                                                      ),
                                                    Text(
                                                      sticker
                                                          .aiExtractedSummary,
                                                      style: const TextStyle(
                                                        fontSize: 10,
                                                        height: 1.35,
                                                        color: Colors.black87,
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }),

                                    // [핵심 5] 흘려 쓴 손필기 → 깔끔한 인쇄체·수식·비교표 정돈 박스 오버레이
                                    ..._currentPageCleanBlocks.map((block) {
                                      final left = (block.normalizedPosition.dx *
                                              pageSize.width)
                                          .clamp(8.0, pageSize.width - 310);
                                      final top = (block.normalizedPosition.dy *
                                              pageSize.height)
                                          .clamp(8.0, pageSize.height - 165);
                                      return Positioned(
                                        left: left,
                                        top: top,
                                        width: 302,
                                        child: GestureDetector(
                                          onPanUpdate: (details) {
                                            setState(() {
                                              final nx = ((left +
                                                          details.delta.dx) /
                                                      pageSize.width)
                                                  .clamp(0.02, 0.65);
                                              final ny = ((top +
                                                          details.delta.dy) /
                                                      pageSize.height)
                                                  .clamp(0.05, 0.82);
                                              block.normalizedPosition =
                                                  Offset(nx, ny);
                                            });
                                          },
                                          child: Material(
                                            elevation: 4,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            color: const Color(0xFFF8FAFF),
                                            child: Container(
                                              padding: const EdgeInsets.all(9),
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color:
                                                      const Color(0xFF1565C0),
                                                  width: 1.4,
                                                ),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Row(
                                                    children: [
                                                      const Icon(
                                                        Icons
                                                            .auto_fix_high_outlined,
                                                        size: 13,
                                                        color:
                                                            Color(0xFF1565C0),
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Expanded(
                                                        child: Text(
                                                          block.headerTitle,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style:
                                                              const TextStyle(
                                                            fontSize: 10,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            color: Color(
                                                                0xFF0D47A1),
                                                          ),
                                                        ),
                                                      ),
                                                      InkWell(
                                                        onTap: () {
                                                          setState(() {
                                                            _currentPageCleanBlocks
                                                                .remove(block);
                                                          });
                                                        },
                                                        child: const Icon(
                                                          Icons.close,
                                                          size: 14,
                                                          color: Colors.black54,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 5),
                                                  // 표시 모드 전환 칩 (비교표 / 수식 / 인쇄체)
                                                  Row(
                                                    children: [
                                                      _buildCleanBlockModeTab(
                                                        block: block,
                                                        style: CleanBlockStyle
                                                            .comparisonTable,
                                                        label: '정돈 비교표',
                                                      ),
                                                      const SizedBox(width: 4),
                                                      _buildCleanBlockModeTab(
                                                        block: block,
                                                        style: CleanBlockStyle
                                                            .mathChemFormula,
                                                        label: '정돈 수식',
                                                      ),
                                                      const SizedBox(width: 4),
                                                      _buildCleanBlockModeTab(
                                                        block: block,
                                                        style: CleanBlockStyle
                                                            .typesetSummary,
                                                        label: '인쇄체 요약',
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 6),
                                                  if (block.activeStyle ==
                                                      CleanBlockStyle
                                                          .comparisonTable)
                                                    Table(
                                                      border: TableBorder.all(
                                                        color: Colors
                                                            .blue.shade200,
                                                        width: 0.8,
                                                      ),
                                                      children: block
                                                          .comparisonTableRows
                                                          .asMap()
                                                          .entries
                                                          .map((entry) {
                                                        final isHeader =
                                                            entry.key == 0;
                                                        return TableRow(
                                                          decoration:
                                                              BoxDecoration(
                                                            color: isHeader
                                                                ? const Color(
                                                                    0xFFE3F2FD)
                                                                : Colors.white,
                                                          ),
                                                          children: entry.value
                                                              .map(
                                                                (cell) =>
                                                                    Padding(
                                                                  padding:
                                                                      const EdgeInsets
                                                                          .all(
                                                                          4),
                                                                  child: Text(
                                                                    cell,
                                                                    style:
                                                                        TextStyle(
                                                                      fontSize:
                                                                          9,
                                                                      fontWeight: isHeader
                                                                          ? FontWeight
                                                                              .bold
                                                                          : FontWeight
                                                                              .normal,
                                                                      color: Colors
                                                                          .black87,
                                                                    ),
                                                                  ),
                                                                ),
                                                              )
                                                              .toList(),
                                                        );
                                                      }).toList(),
                                                    )
                                                  else if (block.activeStyle ==
                                                      CleanBlockStyle
                                                          .mathChemFormula)
                                                    Container(
                                                      width: double.infinity,
                                                      padding:
                                                          const EdgeInsets.all(
                                                              6),
                                                      decoration: BoxDecoration(
                                                        color: Colors.white,
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(6),
                                                      ),
                                                      child: Text(
                                                        block.cleanFormulaLatex,
                                                        style: const TextStyle(
                                                          fontSize: 10,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          fontFamily:
                                                              'monospace',
                                                          color:
                                                              Color(0xFFD81B60),
                                                        ),
                                                      ),
                                                    )
                                                  else
                                                    Text(
                                                      block.cleanSummaryText,
                                                      style: const TextStyle(
                                                        fontSize: 9.5,
                                                        height: 1.35,
                                                        color: Colors.black87,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }),

                                    // 라이브 스터디룸(Co-Study) 스터디원 실시간 펜슬 레이저 커서 오버레이
                                    if (_isCoStudyRoomActive)
                                      ..._coStudyPeers
                                          .where((p) =>
                                              p.activePage == _currentPage)
                                          .map((peer) {
                                        final px = (peer.normalizedPointer.dx *
                                                pageSize.width)
                                            .clamp(8.0, pageSize.width - 140);
                                        final py = (peer.normalizedPointer.dy *
                                                pageSize.height)
                                            .clamp(8.0, pageSize.height - 36);
                                        return Positioned(
                                          left: px,
                                          top: py,
                                          child: IgnorePointer(
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Container(
                                                  width: 12,
                                                  height: 12,
                                                  decoration: BoxDecoration(
                                                    color: peer.cursorColor,
                                                    shape: BoxShape.circle,
                                                    border: Border.all(
                                                      color: Colors.white,
                                                      width: 2,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: peer.cursorColor,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8),
                                                  ),
                                                  child: Text(
                                                    '${peer.peerName} (${peer.deviceLabel})',
                                                    style: const TextStyle(
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      }),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                          ),
                        ),
                      ),
                    ),
                  ),
                    if (_isDualPdfSplitView) ...[
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: _buildSecondaryReferencePdfPane(context),
                      ),
                    ],
                  ],
                ),

                if (_isFloatingSubNoteOpen)
                  Positioned(
                    left: _floatingSubNotePosition.dx,
                    top: _floatingSubNotePosition.dy,
                    child: _buildFloatingSubNoteOverlay(context),
                  ),

                Align(
                  alignment: _isLeftHanded
                      ? Alignment.topRight
                      : Alignment.topCenter,
                  child: Padding(
                    padding:
                        const EdgeInsets.only(top: 10, left: 16, right: 16),
                    child: _buildFloatingPenToolbar(context),
                  ),
                ),
              ],
            ),
          ),

          _buildLectureAudioSyncBar(context),
        ],
      ),
    );
  }

  Widget _buildLectureAudioSyncBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeSeg =
        _lectureAudioSession.segmentAt(_currentAudioPositionMs);
    final maxMs = math.max(
      _lectureAudioSession.totalDurationMs.toDouble(),
      _currentAudioPositionMs.toDouble(),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant, width: 0.8),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: _isRecordingAudio
                      ? colorScheme.errorContainer
                      : colorScheme.secondaryContainer,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _isTranscribingAudio ? null : _toggleAudioRecording,
                icon: Icon(
                  _isRecordingAudio
                      ? Icons.stop_circle_outlined
                      : Icons.mic_none_outlined,
                  size: 17,
                  color: _isRecordingAudio
                      ? colorScheme.onErrorContainer
                      : colorScheme.onSecondaryContainer,
                ),
                label: Text(
                  _isTranscribingAudio
                      ? 'Gemini 전사·요약 중...'
                      : (_isRecordingAudio
                          ? '녹음 종료 & AI 전사'
                          : '강의 녹음'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _isRecordingAudio
                        ? colorScheme.onErrorContainer
                        : colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                visualDensity: VisualDensity.compact,
                tooltip: _isPlayingAudio ? '오디오 일시정지' : '필기 싱크 오디오 재생',
                icon: Icon(
                  _isPlayingAudio ? Icons.pause : Icons.play_arrow,
                  size: 18,
                ),
                onPressed: _toggleAudioPlayback,
              ),
              const SizedBox(width: 8),
              Text(
                '${_formatMs(_currentAudioPositionMs)} / ${_formatMs(maxMs.round())}',
                style: const TextStyle(
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w600,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: SizedBox(
                    height: 30,
                    child: LayoutBuilder(
                      builder: (context, waveConstraints) {
                        final width = waveConstraints.maxWidth;
                        void seekFromLocalDx(double dx) {
                          if (width <= 0) return;
                          final ratio = (dx / width).clamp(0.0, 1.0);
                          final targetMs = (ratio * maxMs).round();
                          setState(() {
                            _currentAudioPositionMs = targetMs;
                          });
                        }

                        return GestureDetector(
                          onTapDown: (d) =>
                              seekFromLocalDx(d.localPosition.dx),
                          onHorizontalDragUpdate: (d) =>
                              seekFromLocalDx(d.localPosition.dx),
                          child: Tooltip(
                            message:
                                '파형 미니맵 (주황색 🔥 = 교수님 음성 데시벨 강조 피크 구간, 탭·드래그하여 즉시 이동)',
                            child: CustomPaint(
                              painter: LectureWaveformPeakPainter(
                                currentPositionMs: _currentAudioPositionMs,
                                totalDurationMs: maxMs.round(),
                                strokes: _currentPageStrokes,
                                decibelPeakTimestampsMs: const [
                                  12500,
                                  28500,
                                  45500,
                                ],
                                primaryColor: colorScheme.primary,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              ActionChip(
                avatar: Icon(
                  _activeTranscriptSearchQuery.isNotEmpty
                      ? Icons.manage_search
                      : Icons.subtitles_outlined,
                  size: 15,
                ),
                label: Text(
                  _activeTranscriptSearchQuery.isNotEmpty
                      ? '검색: "$_activeTranscriptSearchQuery" (${_highlightedStrokeIds.length}획)'
                      : 'AI 전사 대본 검색 (${_lectureAudioSession.segments.length})',
                  style: const TextStyle(fontSize: 11),
                ),
                visualDensity: VisualDensity.compact,
                onPressed: _showAudioTranscriptSheet,
              ),
              if (_activeTranscriptSearchQuery.isNotEmpty) ...[
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: '키워드 필기 하이라이트 해제',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _applyTranscriptKeywordSearch(
                    '',
                    jumpAudioToFirstMatch: false,
                  ),
                ),
              ],
              const SizedBox(width: 6),
              ActionChip(
                avatar: Icon(
                  _isPlaylistModeActive
                      ? Icons.headphones
                      : Icons.playlist_play,
                  size: 15,
                  color: _isPlaylistModeActive
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                label: Text(
                  _isPlaylistModeActive && _audiobookPlaylist.isNotEmpty
                      ? '오디오북 ${_currentPlaylistTrackIndex + 1}/${_audiobookPlaylist.length} (${_playbackSpeed}x)'
                      : '오디오북 연속재생',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: _isPlaylistModeActive
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  if (_isPlaylistModeActive) {
                    _stopAudiobookPlaylist();
                  } else {
                    _buildAndStartAudiobookPlaylist(
                      keywordFilter: _activeTranscriptSearchQuery,
                      strokeLinkedOnly: false,
                    );
                  }
                },
              ),
              const SizedBox(width: 6),
              FilterChip(
                avatar: Icon(
                  Icons.quiz_outlined,
                  size: 14,
                  color: _isVoiceClozeQuizMode
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
                label: Text(
                  _isVoiceClozeQuizMode
                      ? '음성 빈칸 퀴즈 ($_voiceQuizSolvedCount회 인출)'
                      : '음성 빈칸 퀴즈',
                  style: const TextStyle(fontSize: 11),
                ),
                selected: _isVoiceClozeQuizMode,
                visualDensity: VisualDensity.compact,
                onSelected: (val) {
                  if (val) {
                    _startVoiceClozeQuizPlaylist(
                      keywordFilter: _activeTranscriptSearchQuery,
                    );
                  } else {
                    setState(() {
                      _isVoiceClozeQuizMode = false;
                      _activeQuizPausedMask = null;
                    });
                  }
                },
              ),
              const SizedBox(width: 6),
              ActionChip(
                avatar: const Icon(Icons.auto_stories_outlined, size: 15),
                label: Text(
                  _isGeneratingCheatSheet
                      ? '1p 요약 생성중...'
                      : '시험 직전 1p 요약본',
                  style: const TextStyle(fontSize: 11),
                ),
                visualDensity: VisualDensity.compact,
                onPressed: _isGeneratingCheatSheet
                    ? null
                    : () {
                        if (_latestOnePageCheatSheet != null &&
                            _audiobookPlaylist.isEmpty) {
                          _showOnePageCheatSheetModal(
                              _latestOnePageCheatSheet!);
                        } else {
                          _generateAndShowOnePageCheatSheet(
                            keywordFilter: _activeTranscriptSearchQuery,
                          );
                        }
                      },
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: const Text(
                  '필기 리플레이',
                  style: TextStyle(fontSize: 11),
                ),
                selected: _enableAudioReplayFilter,
                visualDensity: VisualDensity.compact,
                onSelected: (val) =>
                    setState(() => _enableAudioReplayFilter = val),
              ),
            ],
          ),
          if (_activeQuizPausedMask != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFD81B60).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFFD81B60),
                    width: 1.2,
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.pause_presentation_outlined,
                      size: 17,
                      color: Color(0xFFD81B60),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '🎤 음성 빈칸 퀴즈 일시정지! 교수님이 정답을 말씀하시기 직전입니다. 빈칸 정답을 떠올린 뒤 가림막을 탭하거나 우측 버튼을 누르세요.',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFD81B60),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFD81B60),
                        foregroundColor: Colors.white,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () =>
                          _revealQuizMaskAndResumeAudio(_activeQuizPausedMask!),
                      icon: const Icon(Icons.lock_open, size: 15),
                      label: const Text(
                        '정답 개봉 & 교수님 설명 이어듣기',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_isPlaylistModeActive && _audiobookPlaylist.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.queue_music,
                      size: 15,
                      color: colorScheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '[트랙 ${_currentPlaylistTrackIndex + 1}/${_audiobookPlaylist.length}] $_playlistTitle',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onTertiaryContainer,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '현재 구간: ${_audiobookPlaylist[_currentPlaylistTrackIndex.clamp(0, _audiobookPlaylist.length - 1)].segment.formattedRange} · 연동 필기 ${_audiobookPlaylist[_currentPlaylistTrackIndex.clamp(0, _audiobookPlaylist.length - 1)].linkedStrokes.length}획 하이라이트',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_previous, size: 16),
                      tooltip: '이전 하이라이트 구간',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      onPressed: () => _skipPlaylistTrack(-1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next, size: 16),
                      tooltip: '다음 하이라이트 구간',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      onPressed: () => _skipPlaylistTrack(1),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: _cyclePlaybackSpeed,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.surface,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${_playbackSpeed}x',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        _playlistLoopEnabled
                            ? Icons.repeat_one_on
                            : Icons.repeat,
                        size: 15,
                      ),
                      tooltip: _playlistLoopEnabled ? '반복 재생 켜짐' : '반복 재생 꺼짐',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      onPressed: () => setState(
                        () => _playlistLoopEnabled = !_playlistLoopEnabled,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 15),
                      tooltip: '오디오북 플레이리스트 종료',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      onPressed: _stopAudiobookPlaylist,
                    ),
                  ],
                ),
              ),
            ),
          if (activeSeg != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.graphic_eq,
                    size: 15,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      activeSeg.keyConceptTag,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: RichText(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      text: _buildHighlightedTextSpan(
                        fullText: _isVoiceClozeQuizMode &&
                                _isPlaylistModeActive &&
                                _audiobookPlaylist.isNotEmpty
                            ? _audiobookPlaylist[_currentPlaylistTrackIndex
                                    .clamp(0, _audiobookPlaylist.length - 1)]
                                .clozeMaskedTranscript
                            : activeSeg.transcriptText,
                        query: _activeTranscriptSearchQuery,
                        baseColor: colorScheme.onSurfaceVariant,
                        highlightBgColor: const Color(0xFFFFEE58),
                        highlightTextColor: Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  bool _shouldAcceptPointer(PointerEvent event) {
    if (_selectedTool == DrawingTool.audioSeek) return true;
    if (!_stylusOnlyMode) return true;
    return event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus ||
        event.kind == PointerDeviceKind.mouse;
  }

  void _handlePointerDown(PointerDownEvent event, Size pageSize) {
    // 갤럭시 S펜 측면 버튼(kSecondaryStylusButton / kPrimaryStylusButton) 또는 역방향 지우개 감지 시 도구 즉시 전환
    if ((event.buttons & kSecondaryStylusButton) != 0 ||
        (event.buttons & kPrimaryStylusButton) != 0 ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _handleHardwareStylusQuickSwitch(sourceLabel: 'S펜 측면 버튼');
      return;
    }
    if (!_shouldAcceptPointer(event)) return;

    final nx = (event.localPosition.dx / pageSize.width).clamp(0.0, 1.0);
    final ny = (event.localPosition.dy / pageSize.height).clamp(0.0, 1.0);

    if (_selectedTool == DrawingTool.audioSeek) {
      final tapOffset = Offset(nx, ny);
      for (final stroke in _currentPageStrokes.reversed) {
        if (stroke.hitTest(tapOffset)) {
          _seekAudioToStroke(stroke);
          return;
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('탭한 위치에 오디오 타임스탬프가 연동된 필기 획이 없습니다. 필기 선 위를 탭해 보세요.'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (_selectedTool == DrawingTool.strokeMove) {
      final tapOffset = Offset(nx, ny);
      for (final stroke in _currentPageStrokes.reversed) {
        if (stroke.hitTest(tapOffset, tolerance: 0.04)) {
          setState(() {
            _movingTargetStroke = stroke;
            _lastMovePointerNormalized = tapOffset;
            _highlightedStrokeIds
              ..clear()
              ..add(stroke.strokeId);
          });
          return;
        }
      }
      return;
    }

    if (_selectedTool == DrawingTool.maskingTape) {
      setState(() {
        _maskDragStartNormalized = Offset(nx, ny);
        _maskDragCurrentNormalized = Offset(nx, ny);
      });
      return;
    }

    if (_selectedTool == DrawingTool.aiLasso) {
      setState(() {
        _lassoDragStartNormalized = Offset(nx, ny);
        _lassoDragCurrentNormalized = Offset(nx, ny);
      });
      return;
    }

    final isHighlighter = _selectedTool == DrawingTool.highlighter;
    final int stampMs = _currentAudioPositionMs;

    setState(() {
      _activeStroke = NormalizedStroke(
        strokeId: 's_${DateTime.now().millisecondsSinceEpoch}',
        tool: _selectedTool,
        color: isHighlighter
            ? const Color(0x66FFEE58)
            : const Color(0xFF1565C0),
        normalizedWidth: isHighlighter ? 0.022 : 0.0035,
        recordingSessionId: _lectureAudioSession.sessionId,
        audioStartMs: stampMs,
        audioEndMs: stampMs,
        points: [
          NormalizedPoint(
            x: nx,
            y: ny,
            pressure: event.pressure,
            audioOffsetMs: stampMs,
          ),
        ],
      );
    });
  }

  void _handlePointerMove(PointerMoveEvent event, Size pageSize) {
    if (!_shouldAcceptPointer(event)) return;
    if (_selectedTool == DrawingTool.audioSeek) return;

    final nx = (event.localPosition.dx / pageSize.width).clamp(0.0, 1.0);
    final ny = (event.localPosition.dy / pageSize.height).clamp(0.0, 1.0);

    if (_selectedTool == DrawingTool.strokeMove) {
      if (_movingTargetStroke != null && _lastMovePointerNormalized != null) {
        final dx = nx - _lastMovePointerNormalized!.dx;
        final dy = ny - _lastMovePointerNormalized!.dy;
        setState(() {
          _movingTargetStroke!.translateStroke(dx, dy);
          _lastMovePointerNormalized = Offset(nx, ny);
        });
      }
      return;
    }

    if (_selectedTool == DrawingTool.maskingTape &&
        _maskDragStartNormalized != null) {
      setState(() {
        _maskDragCurrentNormalized = Offset(nx, ny);
      });
      return;
    }

    if (_selectedTool == DrawingTool.aiLasso &&
        _lassoDragStartNormalized != null) {
      setState(() {
        _lassoDragCurrentNormalized = Offset(nx, ny);
      });
      return;
    }

    if (_activeStroke != null) {
      final int stampMs = _currentAudioPositionMs;
      setState(() {
        _activeStroke!.audioEndMs = stampMs;
        _activeStroke!.points.add(
          NormalizedPoint(
            x: nx,
            y: ny,
            pressure: event.pressure,
            audioOffsetMs: stampMs,
          ),
        );
      });

      // [TOP 1] 굿노트 스타일 Hold-to-Snap 타이머:
      // 펜을 떼지 않고 420ms 동안 멈추면 직선·사각형·원형으로 즉시 보정!
      _shapeSnapHoldTimer?.cancel();
      if (_enableHoldToSnapShape && _activeStroke!.points.length >= 6) {
        _shapeSnapHoldTimer = Timer(const Duration(milliseconds: 420), () {
          if (!mounted || _activeStroke == null) return;
          final snappedLabel = _activeStroke!.trySnapPointsToCleanShape();
          if (snappedLabel != null) {
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '📐 자동 도형 보정(Hold-to-Snap) 완료: $snappedLabel',
                ),
                duration: const Duration(milliseconds: 1300),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        });
      }
    }
  }

  void _handlePointerUp(PointerUpEvent event, Size pageSize) {
    _shapeSnapHoldTimer?.cancel();
    if (_selectedTool == DrawingTool.audioSeek) return;

    if (_selectedTool == DrawingTool.strokeMove) {
      if (_movingTargetStroke != null) {
        setState(() {
          _movingTargetStroke = null;
          _lastMovePointerNormalized = null;
        });
        _persistCurrentPageAnnotations();
      }
      return;
    }

    if (_selectedTool == DrawingTool.maskingTape &&
        _maskDragStartNormalized != null &&
        _maskDragCurrentNormalized != null) {
      final rect = Rect.fromPoints(
        _maskDragStartNormalized!,
        _maskDragCurrentNormalized!,
      );
      if (rect.width > 0.04 && rect.height > 0.02) {
        setState(() {
          _currentPageMasks.add(
            NormalizedMaskRect(
              maskId: 'm_${DateTime.now().millisecondsSinceEpoch}',
              pageNumber: _currentPage,
              normalizedRect: rect,
              hintKeyword: '사용자 지정 암기 영역 (p.$_currentPage)',
              isRevealed: false,
            ),
          );
        });
        _persistCurrentPageAnnotations();
      }
      setState(() {
        _maskDragStartNormalized = null;
        _maskDragCurrentNormalized = null;
      });
      return;
    }

    if (_selectedTool == DrawingTool.aiLasso &&
        _lassoDragStartNormalized != null &&
        _lassoDragCurrentNormalized != null) {
      final lassoRect = Rect.fromPoints(
        _lassoDragStartNormalized!,
        _lassoDragCurrentNormalized!,
      );
      setState(() {
        _lassoDragStartNormalized = null;
        _lassoDragCurrentNormalized = null;
      });
      if (lassoRect.width > 0.05 && lassoRect.height > 0.03) {
        _processAiLassoSelection(lassoRect);
      }
      return;
    }

    if (_activeStroke != null) {
      _activeStroke!.audioEndMs = _currentAudioPositionMs;
      setState(() {
        _currentPageStrokes.add(_activeStroke!);
        _activeStroke = null;
      });
      _persistCurrentPageAnnotations();
    }
  }

  Widget _buildFloatingPenToolbar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(999),
      color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.94),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _buildToolButton(
              tool: DrawingTool.panScroll,
              icon: Icons.pan_tool_alt_outlined,
              label: '페이지 이동',
            ),
            _buildToolButton(
              tool: DrawingTool.pen,
              icon: Icons.edit,
              label: '펜',
            ),
            _buildToolButton(
              tool: DrawingTool.highlighter,
              icon: Icons.format_paint,
              label: '형광펜',
            ),
            _buildToolButton(
              tool: DrawingTool.strokeMove,
              icon: Icons.open_with,
              label: '필기 이동',
            ),
            _buildToolButton(
              tool: DrawingTool.audioSeek,
              icon: Icons.touch_app_outlined,
              label: '오디오 점프(획 탭)',
            ),
            _buildToolButton(
              tool: DrawingTool.maskingTape,
              icon: Icons.visibility_off_outlined,
              label: '암기 가림막',
            ),
            _buildToolButton(
              tool: DrawingTool.aiLasso,
              icon: Icons.gesture,
              label: _isAnalyzingLasso ? 'AI 올가미 분석중...' : 'AI 올가미',
            ),
            const SizedBox(width: 4),
            FilterChip(
              label: const Text('펜 전용(팜리젝션)', style: TextStyle(fontSize: 11)),
              selected: _stylusOnlyMode,
              visualDensity: VisualDensity.compact,
              onSelected: (val) => setState(() => _stylusOnlyMode = val),
            ),
            FilterChip(
              avatar: const Icon(Icons.draw_outlined, size: 15),
              label: const Text('손글씨 빈칸 채점', style: TextStyle(fontSize: 11)),
              selected: _isHandwritingGradingMode,
              visualDensity: VisualDensity.compact,
              onSelected: (val) =>
                  setState(() => _isHandwritingGradingMode = val),
            ),
            ActionChip(
              avatar: const Icon(Icons.swap_horiz, size: 15),
              label: const Text('펜슬 더블탭 전환', style: TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              onPressed: () => _handleHardwareStylusQuickSwitch(
                sourceLabel: 'Apple Pencil 더블탭 / S펜 버튼',
              ),
            ),
            ActionChip(
              avatar: const Icon(Icons.add_a_photo_outlined, size: 15),
              label: const Text('칠판 판서 스티커', style: TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              onPressed: _insertChalkboardPhotoSticker,
            ),
            FilterChip(
              avatar: const Icon(Icons.auto_fix_high, size: 14),
              label: const Text('도형 자동보정', style: TextStyle(fontSize: 11)),
              selected: _enableHoldToSnapShape,
              visualDensity: VisualDensity.compact,
              onSelected: (val) =>
                  setState(() => _enableHoldToSnapShape = val),
            ),
            FilterChip(
              avatar: const Icon(Icons.book_outlined, size: 14),
              label: Text(
                '플로팅 서브노트 (${_subNoteScrapClips.length})',
                style: const TextStyle(fontSize: 11),
              ),
              selected: _isFloatingSubNoteOpen,
              visualDensity: VisualDensity.compact,
              onSelected: (val) =>
                  setState(() => _isFloatingSubNoteOpen = val),
            ),
            ActionChip(
              avatar: const Icon(Icons.grid_view_rounded, size: 14),
              label: Text(
                '썸네일·여백추가 ($_totalPages)',
                style: const TextStyle(fontSize: 11),
              ),
              visualDensity: VisualDensity.compact,
              onPressed: _showPageThumbnailGridAndInsertModal,
            ),
            FilterChip(
              avatar: const Icon(Icons.vertical_split_outlined, size: 14),
              label: Text(
                '듀얼 PDF 비교 (${_crossDocPins.length}핀)',
                style: const TextStyle(fontSize: 11),
              ),
              selected: _isDualPdfSplitView,
              visualDensity: VisualDensity.compact,
              onSelected: (val) => setState(() => _isDualPdfSplitView = val),
            ),
            ActionChip(
              avatar: const Icon(Icons.table_chart_outlined, size: 14),
              label: Text(
                _isConvertingHandwriting ? '정돈 변환중...' : '손필기→인쇄체·표 정돈',
                style: const TextStyle(fontSize: 11),
              ),
              visualDensity: VisualDensity.compact,
              onPressed: _isConvertingHandwriting
                  ? null
                  : _convertCurrentPageStrokesToCleanTypesetBlock,
            ),
            IconButton(
              icon: const Icon(Icons.chevron_left, size: 18),
              tooltip: '이전 페이지',
              visualDensity: VisualDensity.compact,
              onPressed: _currentPage > 1
                  ? () => _jumpToCitedPage(_currentPage - 1)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right, size: 18),
              tooltip: '다음 페이지',
              visualDensity: VisualDensity.compact,
              onPressed: _currentPage < _totalPages
                  ? () => _jumpToCitedPage(_currentPage + 1)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.undo, size: 18),
              tooltip: '현재 페이지 마지막 필기 취소 (동기화 반영)',
              visualDensity: VisualDensity.compact,
              onPressed: _currentPageStrokes.isEmpty
                  ? null
                  : () {
                      setState(() {
                        final removed = _currentPageStrokes.removeLast();
                        _currentPageDeletedIds.add(removed.strokeId);
                      });
                      _persistCurrentPageAnnotations();
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolButton({
    required DrawingTool tool,
    required IconData icon,
    required String label,
  }) {
    final isSelected = _selectedTool == tool;
    return ChoiceChip(
      avatar: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: isSelected,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setState(() {
        if (_selectedTool != tool) {
          _previousDrawingTool = _selectedTool;
        }
        _selectedTool = tool;
      }),
    );
  }

  Widget _buildCleanBlockModeTab({
    required CleanTypesetBlockSticker block,
    required CleanBlockStyle style,
    required String label,
  }) {
    final isSelected = block.activeStyle == style;
    return InkWell(
      onTap: () => setState(() => block.activeStyle = style),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF1565C0)
              : const Color(0xFFE3F2FD),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: isSelected ? Colors.white : const Color(0xFF0D47A1),
          ),
        ),
      ),
    );
  }

  /// [핵심 4] 듀얼 PDF 스플릿 뷰 우측 보조 참조 문서(강의교안 PDF) 및 양방향 교차 핀 패널
  Widget _buildSecondaryReferencePdfPane(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 64, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 상단 교안 컨트롤 & 양방향 핀 연결 바
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.menu_book_outlined,
                      size: 15,
                      color: colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '참조 교안: $_secondaryFileName (p.$_secondaryCurrentPage/$_secondaryTotalPages)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_left, size: 16),
                      visualDensity: VisualDensity.compact,
                      onPressed: _secondaryCurrentPage > 1
                          ? () => setState(() => _secondaryCurrentPage--)
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right, size: 16),
                      visualDensity: VisualDensity.compact,
                      onPressed: _secondaryCurrentPage < _secondaryTotalPages
                          ? () => setState(() => _secondaryCurrentPage++)
                          : null,
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _pickSecondaryReferencePdf,
                      icon: const Icon(Icons.folder_open, size: 14),
                      label: const Text(
                        '교안 변경',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _createCrossDocumentPin,
                      icon: const Icon(Icons.push_pin_outlined, size: 13),
                      label: Text(
                        'p.$_currentPage↔p.$_secondaryCurrentPage 핀 연결',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ],
                ),
                if (_crossDocPins.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _crossDocPins.map((pin) {
                        final isActivePin =
                            pin.primaryPageNumber == _currentPage &&
                                pin.secondaryPageNumber ==
                                    _secondaryCurrentPage;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                            avatar: Icon(
                              Icons.link,
                              size: 13,
                              color: isActivePin
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant,
                            ),
                            label: Text(
                              pin.relationSummary,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: isActivePin
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _jumpToCrossDocumentPin(pin),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),

          // 우측 보조 참조 PDF 페이지 뷰어
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _secondaryPdfBytes != null
                    ? SfPdfViewer.memory(
                        _secondaryPdfBytes!,
                        controller: _secondaryPdfController,
                        pageLayoutMode: PdfPageLayoutMode.single,
                        canShowScrollHead: false,
                        onPageChanged: (details) {
                          setState(() {
                            _secondaryCurrentPage = details.newPageNumber;
                          });
                        },
                      )
                    : Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '$_currentSubjectFolder · 강의교안 참조 뷰어',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blueGrey.shade700,
                                  ),
                                ),
                                Text(
                                  '교안 Page $_secondaryCurrentPage / $_secondaryTotalPages',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 18),
                            Text(
                              _secondaryCurrentPage == 8
                                  ? '[강의교안 p.8 핵심 모식도] 미토콘드리아 내막(크리스테)의 전자전달계 복합체 I·II·III·IV와 ATP 합성효소 배열'
                                  : '[강의교안 p.$_secondaryCurrentPage 핵심 공식] 화학삼투적 인산화와 양성자 구동력(PMF = ΔΨ - 2.3RT/F·ΔpH)',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0F6FF),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFF90CAF9),
                                ),
                              ),
                              child: Text(
                                _secondaryCurrentPage == 8
                                    ? '• 내막(Inner Membrane): 전자전달계 복합체 I~IV 및 F₀F₁-ATP 합성효소 위치 (불투과성 막)
'
                                        '• 막 사이 공간(Intermembrane Space): H⁺ 이온이 능동 수송되어 축적됨 (낮은 pH ≈ 7.0)
'
                                        '• 기질(Matrix): 시트르산 회로(TCA) 효소 존재 (높은 pH ≈ 8.0)'
                                    : '• 수소 이온 농도 기울기(ΔpH)가 F₀ 통로를 통해 기질 쪽으로 확산될 때 발생하는 자유에너지 감소(ΔG < 0)가 ATP 합성을 직접 구동함.
'
                                        '• 좌측 기출문제 p.$_currentPage 문항과 양방향 핀(📌)으로 연결되어 있습니다.',
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.55,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// [TOP 2] 플렉슬(Flexcil) 스타일 플로팅 단권화 서브노트(코넬/줄노트/모눈) & 스크랩북 팝업 위젯
  Widget _buildFloatingSubNoteOverlay(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      elevation: 10,
      borderRadius: BorderRadius.circular(14),
      color: colorScheme.surface,
      child: Container(
        width: 340,
        height: 430,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colorScheme.primary, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 드래그 핸들 헤더 바
            GestureDetector(
              onPanUpdate: (details) {
                setState(() {
                  _floatingSubNotePosition = Offset(
                    (_floatingSubNotePosition.dx + details.delta.dx)
                        .clamp(8.0, 520.0),
                    (_floatingSubNotePosition.dy + details.delta.dy)
                        .clamp(56.0, 360.0),
                  );
                });
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.drag_indicator,
                      size: 16,
                      color: colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '📒 단권화 서브노트 (${_subNoteScrapClips.length}건 스크랩)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    PopupMenuButton<SubNoteTemplate>(
                      tooltip: '노트 속지 양식 변경 (코넬/줄노트/모눈)',
                      initialValue: _subNoteTemplate,
                      onSelected: (tpl) =>
                          setState(() => _subNoteTemplate = tpl),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: SubNoteTemplate.cornell,
                          child: Text('코넬노트 양식'),
                        ),
                        PopupMenuItem(
                          value: SubNoteTemplate.ruled,
                          child: Text('줄노트 양식'),
                        ),
                        PopupMenuItem(
                          value: SubNoteTemplate.grid,
                          child: Text('모눈종이 양식'),
                        ),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.surface,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _subNoteTemplate.name.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () =>
                          setState(() => _isFloatingSubNoteOpen = false),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 현재 페이지 원탭 스크랩 버튼 바
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _scrapCurrentPageHighlightToSubNote,
                      icon: const Icon(Icons.content_cut, size: 14),
                      label: Text(
                        '+ 현재 p.$_currentPage 핵심 영역 스크랩',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (_subNoteFreehandStrokes.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.cleaning_services_outlined,
                          size: 15),
                      tooltip: '서브노트 손필기 지우기',
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          setState(() => _subNoteFreehandStrokes.clear()),
                    ),
                ],
              ),
            ),

            // 스크랩된 원본 PDF 발췌 카드 목록 (탭 시 원본 페이지 & 녹음 시점으로 즉시 이동)
            Expanded(
              flex: 5,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _subNoteScrapClips.length,
                itemBuilder: (ctx, i) {
                  final clip = _subNoteScrapClips[i];
                  return Card(
                    elevation: 0,
                    color: colorScheme.surfaceContainerLow,
                    margin: const EdgeInsets.only(bottom: 6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        _jumpToCitedPage(clip.sourcePageNumber);
                        if (clip.linkedAudioMs != null) {
                          setState(() {
                            _currentAudioPositionMs = clip.linkedAudioMs!;
                            _isPlayingAudio = true;
                          });
                          _startAudioClock();
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primary,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '🔗 원본 p.${clip.sourcePageNumber} 이동',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onPrimary,
                                    ),
                                  ),
                                ),
                                if (clip.linkedAudioMs != null) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFD81B60)
                                          .withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '🔊 ${clip.formattedAudioBadge}',
                                      style: const TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFFD81B60),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (clip.croppedImageBytes != null) ...[
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.memory(
                                  clip.croppedImageBytes!,
                                  height: 46,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ],
                            const SizedBox(height: 4),
                            Text(
                              clip.extractedSnippetText,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              clip.userAnnotationMemo,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // 하단 코넬/줄노트/모눈 손필기 패드 영역
            Expanded(
              flex: 4,
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFEF7),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: LayoutBuilder(
                  builder: (ctx, padConstraints) {
                    final padW = padConstraints.maxWidth;
                    final padH = padConstraints.maxHeight;
                    return Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (e) {
                        final nx =
                            (e.localPosition.dx / padW).clamp(0.0, 1.0);
                        final ny =
                            (e.localPosition.dy / padH).clamp(0.0, 1.0);
                        setState(() {
                          _subNoteFreehandStrokes.add([Offset(nx, ny)]);
                        });
                      },
                      onPointerMove: (e) {
                        if (_subNoteFreehandStrokes.isEmpty) return;
                        final nx =
                            (e.localPosition.dx / padW).clamp(0.0, 1.0);
                        final ny =
                            (e.localPosition.dy / padH).clamp(0.0, 1.0);
                        setState(() {
                          _subNoteFreehandStrokes.last.add(Offset(nx, ny));
                        });
                      },
                      child: CustomPaint(
                        painter: SubNoteTemplateAndInkPainter(
                          template: _subNoteTemplate,
                          strokes: _subNoteFreehandStrokes,
                        ),
                        child: _subNoteFreehandStrokes.isEmpty
                            ? const Center(
                                child: Text(
                                  '✍️ 코넬/줄노트 필기 영역 (펜슬로 자유롭게 요약 필기)',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.black45,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimulatedPdfPageContent() {
    final insertedTpl = _insertedNotePages[_currentPage];
    if (insertedTpl != null) {
      return CustomPaint(
        painter: SubNoteTemplateAndInkPainter(
          template: insertedTpl,
          strokes: const [],
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '[$_currentSubjectFolder · 삽입된 ${insertedTpl.name.toUpperCase()} 풀이 여백 노트]',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1565C0),
                    ),
                  ),
                  Text(
                    'Page $_currentPage / $_totalPages',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$_currentSubjectFolder · $_currentSubTopic ($_currentDocType)',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'Page $_currentPage / $_totalPages',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
          const Divider(height: 24),
          const Text(
            '문항 14. 진핵세포의 세포호흡 과정에서 전자전달계와 화학삼투적 인산화에 대한 핵심 정리',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            '1) 산화적 인산화의 장소:\n'
            '진핵세포에서 전자전달계 복합체(I~IV)와 ATP 합성효소는 [                         ]에 존재한다.',
            style: TextStyle(fontSize: 14, height: 1.8, color: Colors.black87),
          ),
          const SizedBox(height: 24),
          const Text(
            '2) ATP 합성의 구동력:\n'
            '막 사이 공간으로 펌핑된 수소 이온에 의해 형성된 [                         ]가 ATP 합성효소를 통과하며 ADP를 인산화한다.',
            style: TextStyle(fontSize: 14, height: 1.8, color: Colors.black87),
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: _pickAndClassifyPdf,
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('내 태블릿에서 실제 PDF 열기'),
              ),
              OutlinedButton.icon(
                onPressed: _showFlattenExportDialog,
                icon: const Icon(Icons.ios_share, size: 16),
                label: const Text('필기+요약 PDF 합본 저장'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGeminiNotebookAndTimerSidebar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final allMasks = _masksByPage.values.expand((e) => e).toList();

    return Container(
      color: colorScheme.surface,
      child: Column(
        children: [
          TabBar(
            controller: _sidebarTabController,
            tabs: [
              const Tab(text: '제미나이 노트북 Q&A'),
              Tab(text: '시험 일정 & 오답 (${_studyCards.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _sidebarTabController,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer
                              .withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '연결된 노트북 소스: $_currentFileName (${_extractedPageTexts.length}개 페이지 + 강의 음성 세그먼트 ${_lectureAudioSession.segments.length}개)\n'
                          '질문 시 Gemini가 근거 페이지와 강의 시점을 찾아 답변합니다.',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _notebookQaHistory.length,
                          itemBuilder: (context, idx) {
                            final item = _notebookQaHistory[idx];
                            return Card(
                              elevation: 0,
                              color: colorScheme.surfaceContainerLow,
                              margin: const EdgeInsets.only(bottom: 10),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '질문: ${item.question}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const Divider(height: 14),
                                    Text(
                                      item.answer,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        height: 1.45,
                                      ),
                                    ),
                                    if (item.citedPages.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 6,
                                        children: item.citedPages
                                            .map(
                                              (page) => ActionChip(
                                                avatar: const Icon(
                                                  Icons.find_in_page_outlined,
                                                  size: 15,
                                                ),
                                                label: Text(
                                                  '출처: p.$page 이동',
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                  ),
                                                ),
                                                onPressed: () =>
                                                    _jumpToCitedPage(page),
                                              ),
                                            )
                                            .toList(),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      if (_isAskingNotebook)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      TextField(
                        controller: _questionController,
                        onSubmitted: (_) => _submitNotebookQuestion(),
                        decoration: InputDecoration(
                          hintText: '현재 PDF 자료에 대해 질문하기...',
                          hintStyle: const TextStyle(fontSize: 12),
                          isDense: true,
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.send, size: 18),
                            onPressed: _submitNotebookQuestion,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Card(
                      elevation: 0,
                      color: colorScheme.surfaceContainerLow,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$_currentSubjectFolder · $_examDdayLabel',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: _readCount / _targetReadCount,
                              minHeight: 8,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '목표 회독 달성률: $_readCount / $_targetReadCount 회독',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: _showAiStudyPlannerModal,
                                  icon: const Icon(
                                    Icons.calendar_today_outlined,
                                    size: 14,
                                  ),
                                  label: const Text(
                                    '오늘 분량 AI 배분',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_isAnalyzingLasso) ...[
                      const SizedBox(height: 10),
                      Card(
                        elevation: 0,
                        color: colorScheme.secondaryContainer,
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'AI 올가미 영역을 캡처해 Gemini가 해설과 유사 변형 문제를 생성하고 있습니다...',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Text(
                            'AI 올가미 오답 & 유사 변형 문제',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _isExportingPdf
                              ? null
                              : _generateAndOpenMasterWrongAnswerBookPdf,
                          icon: const Icon(
                            Icons.menu_book_outlined,
                            size: 14,
                          ),
                          label: const Text(
                            '통합 오답노트 PDF',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ..._studyCards.map(
                      (card) => Card(
                        elevation: 0,
                        color: colorScheme.surfaceContainerLow,
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      card.recognizedQuestion,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  ActionChip(
                                    label: Text(
                                      'p.${card.pageNumber}',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () =>
                                        _jumpToCitedPage(card.pageNumber),
                                  ),
                                ],
                              ),
                              if (card.croppedImageBytes != null) ...[
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 110,
                                    ),
                                    child: Image.memory(
                                      card.croppedImageBytes!,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              Text(
                                'Gemini 단계별 해설:\n${card.stepByStepSolution}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.45,
                                ),
                              ),
                              const Divider(height: 16),
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: colorScheme.primaryContainer
                                      .withValues(alpha: 0.4),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      card.twinQuestion,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    if (card.isTwinAnswerRevealed)
                                      Text(
                                        card.twinAnswer,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      )
                                    else
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton.icon(
                                          onPressed: () {
                                            setState(() {
                                              card.isTwinAnswerRevealed = true;
                                            });
                                          },
                                          icon: const Icon(
                                            Icons.lightbulb_outline,
                                            size: 15,
                                          ),
                                          label: const Text(
                                            '유사 문제 정답 및 포인트 보기',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Text(
                            '에빙하우스 스마트 복습 & 가림막 큐',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _startWeakMaskHandwritingRetest,
                          icon: const Icon(Icons.draw_outlined, size: 15),
                          label: const Text(
                            '약점 손글씨 재시험',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...(allMasks.toList()
                          ..sort((a, b) => a.reviewSchedule.nextReviewAt
                              .compareTo(b.reviewSchedule.nextReviewAt)))
                        .map(
                      (m) => Card(
                        elevation: 0,
                        color: m.reviewSchedule.isDueNow
                            ? colorScheme.errorContainer.withValues(alpha: 0.28)
                            : colorScheme.surfaceContainerLow,
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            m.isRevealed
                                ? Icons.check_circle
                                : (m.reviewSchedule.isDueNow
                                    ? Icons.priority_high
                                    : Icons.schedule_outlined),
                            size: 18,
                            color: m.isRevealed
                                ? const Color(0xFF2E7D32)
                                : (m.reviewSchedule.isDueNow
                                    ? colorScheme.error
                                    : colorScheme.primary),
                          ),
                          title: Text(
                            m.isRevealed
                                ? m.hintKeyword
                                : '가림막 빈칸 (p.${m.pageNumber} · 탭하여 손글씨 테스트)',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            'p.${m.pageNumber} · ${m.reviewSchedule.badgeLabel}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.open_in_new, size: 16),
                            tooltip: '해당 페이지로 이동해 손글씨 채점',
                            onPressed: () {
                              setState(() {
                                _isHandwritingGradingMode = true;
                                m.isRevealed = false;
                              });
                              _jumpToCitedPage(m.pageNumber);
                            },
                          ),
                          onTap: () {
                            setState(() {
                              m.isRevealed = !m.isRevealed;
                            });
                            _persistCurrentPageAnnotations();
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class NormalizedAnnotationPainter extends CustomPainter {
  final List<NormalizedStroke> strokes;
  final NormalizedStroke? activeStroke;
  final Offset? maskPreviewStart;
  final Offset? maskPreviewEnd;
  final Offset? lassoPreviewStart;
  final Offset? lassoPreviewEnd;
  final int currentAudioPositionMs;
  final bool enableAudioReplayFilter;
  final Set<String> highlightedStrokeIds;

  NormalizedAnnotationPainter({
    required this.strokes,
    required this.activeStroke,
    this.maskPreviewStart,
    this.maskPreviewEnd,
    this.lassoPreviewStart,
    this.lassoPreviewEnd,
    required this.currentAudioPositionMs,
    required this.enableAudioReplayFilter,
    required this.highlightedStrokeIds,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final allStrokes = [
      ...strokes,
      if (activeStroke != null) activeStroke!,
    ];

    for (final stroke in allStrokes) {
      if (stroke.points.isEmpty) continue;

      final bool isHighlighted =
          highlightedStrokeIds.contains(stroke.strokeId);
      final bool isFutureStroke = enableAudioReplayFilter &&
          !isHighlighted &&
          stroke.audioStartMs != null &&
          stroke.audioStartMs! > currentAudioPositionMs;

      Color effectiveColor = stroke.color;
      if (isFutureStroke) {
        effectiveColor = stroke.color.withValues(alpha: 0.22);
      }

      if (isHighlighted) {
        final glowPaint = Paint()
          ..color = const Color(0x66D81B60)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke
          ..strokeWidth = (stroke.normalizedWidth * size.width) + 7.0;

        final glowPath = _buildStrokePath(stroke.points, size);
        canvas.drawPath(glowPath, glowPaint);
      }

      final paint = Paint()
        ..color = effectiveColor
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.normalizedWidth * size.width;

      List<NormalizedPoint> visiblePoints = stroke.points;
      if (enableAudioReplayFilter &&
          !isHighlighted &&
          !isFutureStroke &&
          stroke.audioStartMs != null &&
          stroke.audioEndMs != null &&
          currentAudioPositionMs >= stroke.audioStartMs! &&
          currentAudioPositionMs < stroke.audioEndMs!) {
        final filtered = stroke.points
            .where((pt) =>
                pt.audioOffsetMs == null ||
                pt.audioOffsetMs! <= currentAudioPositionMs)
            .toList();
        if (filtered.isNotEmpty) {
          visiblePoints = filtered;
        }
      }

      final path = _buildStrokePath(visiblePoints, size);
      canvas.drawPath(path, paint);
    }

    if (maskPreviewStart != null && maskPreviewEnd != null) {
      final previewRect = Rect.fromPoints(
        Offset(
          maskPreviewStart!.dx * size.width,
          maskPreviewStart!.dy * size.height,
        ),
        Offset(
          maskPreviewEnd!.dx * size.width,
          maskPreviewEnd!.dy * size.height,
        ),
      );
      final fillPaint = Paint()
        ..color = const Color(0x552575FC)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(previewRect, const Radius.circular(6)),
        fillPaint,
      );
    }

    if (lassoPreviewStart != null && lassoPreviewEnd != null) {
      final lassoRect = Rect.fromPoints(
        Offset(
          lassoPreviewStart!.dx * size.width,
          lassoPreviewStart!.dy * size.height,
        ),
        Offset(
          lassoPreviewEnd!.dx * size.width,
          lassoPreviewEnd!.dy * size.height,
        ),
      );
      final fillPaint = Paint()
        ..color = const Color(0x28705EC2)
        ..style = PaintingStyle.fill;
      final borderPaint = Paint()
        ..color = const Color(0xFF705EC2)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;

      final rrect =
          RRect.fromRectAndRadius(lassoRect, const Radius.circular(8));
      canvas.drawRRect(rrect, fillPaint);
      canvas.drawRRect(rrect, borderPaint);
    }
  }

  Path _buildStrokePath(List<NormalizedPoint> pts, Size size) {
    final path = Path();
    if (pts.isEmpty) return path;
    final first = pts.first.toPixelOffset(size);
    path.moveTo(first.dx, first.dy);
    for (int i = 1; i < pts.length; i++) {
      final pt = pts[i].toPixelOffset(size);
      path.lineTo(pt.dx, pt.dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant NormalizedAnnotationPainter oldDelegate) => true;
}

/// 암기 가림막(NormalizedMaskRect) 내부에 애플펜슬·S펜으로 작성한 손글씨 획을 그리는 CustomPainter
class MaskHandwritingPainter extends CustomPainter {
  final List<List<Offset>> strokes;

  MaskHandwritingPainter({required this.strokes});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0D47A1)
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path()
        ..moveTo(
          stroke.first.dx * size.width,
          stroke.first.dy * size.height,
        );
      for (int i = 1; i < stroke.length; i++) {
        path.lineTo(
          stroke[i].dx * size.width,
          stroke[i].dy * size.height,
        );
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant MaskHandwritingPainter oldDelegate) => true;
}


/// 강의 오디오 파형(Waveform) 미니맵 및 교수님 데시벨 피크(강조 구간) 시각화 CustomPainter
class LectureWaveformPeakPainter extends CustomPainter {
  final int currentPositionMs;
  final int totalDurationMs;
  final List<NormalizedStroke> strokes;
  final List<int> decibelPeakTimestampsMs;
  final Color primaryColor;

  LectureWaveformPeakPainter({
    required this.currentPositionMs,
    required this.totalDurationMs,
    required this.strokes,
    required this.decibelPeakTimestampsMs,
    required this.primaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final int safeTotalMs = math.max(totalDurationMs, 1000);
    const int barCount = 56;
    final double barSpacing = size.width / barCount;
    final double barWidth = (barSpacing * 0.58).clamp(2.0, 6.0);
    final double playheadRatio =
        (currentPositionMs / safeTotalMs).clamp(0.0, 1.0);

    for (int i = 0; i < barCount; i++) {
      final double barRatio = (i + 0.5) / barCount;
      final int barTimeMs = (barRatio * safeTotalMs).round();

      // 데시벨 피크(교수님 목소리 강조 시점) 근접 여부 판별
      final bool isNearDecibelPeak = decibelPeakTimestampsMs.any(
        (peakMs) => (barTimeMs - peakMs).abs() <= 1800,
      );

      // 해당 시간대에 필기 획이 존재하는지 판별
      final bool hasStrokeAtBar = strokes.any(
        (s) => s.overlapsTimeRange(barTimeMs - 800, barTimeMs + 800),
      );

      // 의사 난수 + 피크 부스트로 자연스러운 음성 파형 진폭 계산
      final double baseWave =
          0.25 + 0.35 * ((math.sin(i * 0.85) + 1.0) * 0.5);
      final double amplitude = isNearDecibelPeak
          ? (baseWave + 0.38).clamp(0.55, 0.96)
          : (hasStrokeAtBar ? (baseWave + 0.18).clamp(0.4, 0.8) : baseWave);

      final double barHeight = (amplitude * size.height).clamp(4.0, size.height);
      final double left = i * barSpacing + (barSpacing - barWidth) / 2;
      final double top = (size.height - barHeight) / 2;

      final bool isPlayed = barRatio <= playheadRatio;
      final Color barColor = isNearDecibelPeak
          ? (isPlayed ? const Color(0xFFD81B60) : const Color(0xFFFF8F00))
          : (isPlayed
              ? primaryColor
              : primaryColor.withValues(alpha: 0.28));

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, barHeight),
        const Radius.circular(2),
      );
      canvas.drawRRect(rrect, Paint()..color = barColor);
    }

    // 현재 재생 헤드(Playhead) 수직 인디케이터 라인
    final double playheadX = playheadRatio * size.width;
    canvas.drawLine(
      Offset(playheadX, 0),
      Offset(playheadX, size.height),
      Paint()
        ..color = const Color(0xFFD81B60)
        ..strokeWidth = 2.0,
    );
  }

  @override
  bool shouldRepaint(covariant LectureWaveformPeakPainter oldDelegate) =>
      oldDelegate.currentPositionMs != currentPositionMs ||
      oldDelegate.totalDurationMs != totalDurationMs;
}


/// 주간 뽀모도로 순공 시간(막대 그래프) 및 에빙하우스 기억 유지율(꺾은선 그래프)을 그리는 CustomPainter
class StudyAnalyticsChartPainter extends CustomPainter {
  final List<int> dailyStudyMinutes;
  final List<double> retentionRates;
  final Color barColor;
  final Color lineColor;

  StudyAnalyticsChartPainter({
    required this.dailyStudyMinutes,
    required this.retentionRates,
    required this.barColor,
    required this.lineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (dailyStudyMinutes.isEmpty) return;
    final int count = dailyStudyMinutes.length;
    final double slotWidth = size.width / count;
    final double barWidth = (slotWidth * 0.42).clamp(12.0, 36.0);
    final double chartHeight = size.height - 22;

    final barPaint = Paint()..color = barColor.withValues(alpha: 0.72);
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dotPaint = Paint()..color = lineColor;

    final linePath = Path();

    for (int i = 0; i < count; i++) {
      final double cx = (i + 0.5) * slotWidth;
      final double minRatio = (dailyStudyMinutes[i] / 200.0).clamp(0.1, 1.0);
      final double bHeight = minRatio * chartHeight;
      final Rect barRect = Rect.fromLTWH(
        cx - barWidth / 2,
        chartHeight - bHeight,
        barWidth,
        bHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(barRect, const Radius.circular(6)),
        barPaint,
      );

      final double retRatio =
          (i < retentionRates.length ? retentionRates[i] : 0.8).clamp(0.1, 1.0);
      final double ly = chartHeight - (retRatio * chartHeight);
      if (i == 0) {
        linePath.moveTo(cx, ly);
      } else {
        linePath.lineTo(cx, ly);
      }
      canvas.drawCircle(Offset(cx, ly), 4.0, dotPaint);
    }

    canvas.drawPath(linePath, linePaint);
  }

  @override
  bool shouldRepaint(covariant StudyAnalyticsChartPainter oldDelegate) => false;
}


/// 단계별 생물·화학 메커니즘 화살표와 개념 마인드맵 노드를 렌더링하는 CustomPainter
class ConceptMechanismMindMapPainter extends CustomPainter {
  final List<ConceptMindMapNode> nodes;
  final List<ConceptMindMapEdge> edges;
  final Color textColor;

  ConceptMechanismMindMapPainter({
    required this.nodes,
    required this.edges,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final nodeMap = <String, ConceptMindMapNode>{
      for (final n in nodes) n.nodeId: n,
    };

    // 1. 노드 간 화살표 엣지 및 메커니즘 라벨 렌더링
    for (final edge in edges) {
      final from = nodeMap[edge.fromNodeId];
      final to = nodeMap[edge.toNodeId];
      if (from == null || to == null) continue;

      final p1 = Offset(
        from.normalizedCenter.dx * size.width,
        from.normalizedCenter.dy * size.height,
      );
      final p2 = Offset(
        to.normalizedCenter.dx * size.width,
        to.normalizedCenter.dy * size.height,
      );

      final linePaint = Paint()
        ..color = from.accentColor.withValues(alpha: 0.75)
        ..strokeWidth = 2.4
        ..style = PaintingStyle.stroke;

      canvas.drawLine(p1, p2, linePaint);

      // 화살촉(Arrowhead) 계산
      final angle = math.atan2(p2.dy - p1.dy, p2.dx - p1.dx);
      final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
      final arrowPath = Path()
        ..moveTo(mid.dx + 8 * math.cos(angle), mid.dy + 8 * math.sin(angle))
        ..lineTo(
          mid.dx - 7 * math.cos(angle - 0.55),
          mid.dy - 7 * math.sin(angle - 0.55),
        )
        ..lineTo(
          mid.dx - 7 * math.cos(angle + 0.55),
          mid.dy - 7 * math.sin(angle + 0.55),
        )
        ..close();
      canvas.drawPath(arrowPath, Paint()..color = from.accentColor);

      // 엣지 라벨 텍스트
      final tp = TextPainter(
        text: TextSpan(
          text: edge.mechanismLabel,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: from.accentColor,
            backgroundColor: Colors.white.withValues(alpha: 0.88),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(mid.dx - tp.width / 2, mid.dy - tp.height - 6),
      );
    }

    // 2. 각 개념 마인드맵 노드 카드 렌더링
    const double cardW = 166;
    const double cardH = 62;
    for (final node in nodes) {
      final center = Offset(
        node.normalizedCenter.dx * size.width,
        node.normalizedCenter.dy * size.height,
      );
      final rect = Rect.fromCenter(center: center, width: cardW, height: cardH);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));

      canvas.drawRRect(
        rrect,
        Paint()..color = Colors.white,
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = node.accentColor
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke,
      );

      final tp = TextPainter(
        text: TextSpan(
          children: [
            TextSpan(
              text: '${node.title}\n',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: node.accentColor,
              ),
            ),
            TextSpan(
              text: node.subtitle,
              style: const TextStyle(
                fontSize: 10,
                color: Colors.black87,
                height: 1.35,
              ),
            ),
          ],
        ),
        textDirection: TextDirection.ltr,
        maxLines: 3,
      )..layout(maxWidth: cardW - 14);

      tp.paint(
        canvas,
        Offset(rect.left + 7, rect.top + (cardH - tp.height) / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant ConceptMechanismMindMapPainter oldDelegate) =>
      false;
}


/// 코넬노트(Cornell) / 줄노트(Ruled) / 모눈종이(Grid) 속지 라인과 서브노트 손필기를 그리는 CustomPainter
class SubNoteTemplateAndInkPainter extends CustomPainter {
  final SubNoteTemplate template;
  final List<List<Offset>> strokes;

  SubNoteTemplateAndInkPainter({
    required this.template,
    required this.strokes,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = const Color(0xFFD0DFEE)
      ..strokeWidth = 0.8;

    // 가로 줄노트 보조선
    for (double y = 22; y < size.height; y += 20) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    if (template == SubNoteTemplate.grid) {
      for (double x = 20; x < size.width; x += 20) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
      }
    } else if (template == SubNoteTemplate.cornell) {
      final cornellPaint = Paint()
        ..color = const Color(0xFFE57373).withValues(alpha: 0.7)
        ..strokeWidth = 1.4;
      // 좌측 단서(Cue) 세로 구분선 (28% 지점)
      canvas.drawLine(
        Offset(size.width * 0.28, 0),
        Offset(size.width * 0.28, size.height * 0.78),
        cornellPaint,
      );
      // 하단 요약(Summary) 가로 구분선 (78% 지점)
      canvas.drawLine(
        Offset(0, size.height * 0.78),
        Offset(size.width, size.height * 0.78),
        cornellPaint,
      );
    }

    // 서브노트 자유 필기 획 렌더링
    final inkPaint = Paint()
      ..color = const Color(0xFF1A237E)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final s in strokes) {
      if (s.length < 2) continue;
      final path = Path()
        ..moveTo(s.first.dx * size.width, s.first.dy * size.height);
      for (int i = 1; i < s.length; i++) {
        path.lineTo(s[i].dx * size.width, s[i].dy * size.height);
      }
      canvas.drawPath(path, inkPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SubNoteTemplateAndInkPainter oldDelegate) =>
      true;
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'adaptive_study_workspace.dart';

/// ============================================================================
/// 실기기 하드웨어 오디오 엔진 어댑터 (record + just_audio 스트림 바인딩 모듈)
/// ============================================================================
/// - iPad (AVFoundation) 및 Android 태블릿 (MediaRecorder / ExoPlayer) 실기기에서
///   마이크 녹음(`AudioRecorder`)과 무공백 구간 클리핑 재생(`ClippingAudioSource` /
///   `ConcatenatingAudioSource`)을 `AdaptiveStudyWorkspace`의 상태와 바인딩합니다.
class RealDeviceAudioEngineAdapter {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<int?>? _currentIndexSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  String? _activeRecordingFilePath;
  DateTime? _recordingStartedAt;

  /// 현재 하드웨어 마이크 녹음 중 여부
  bool isRecording = false;

  /// 현재 하드웨어 오디오 플레이어 재생 중 여부
  bool get isPlaying => _player.playing;

  /// 1. 실기기 마이크 강의 녹음 시작 (.m4a AAC 인코딩)
  /// 필기 획(NormalizedStroke)이 생성될 때 [currentRecordingElapsedMs]를 조회해
  /// 각 필기 포인트에 정확한 오디오 타임스탬프(audioOffsetMs)를 부여합니다.
  Future<String?> startHardwareLectureRecording({
    required String sessionId,
  }) async {
    final bool hasMicPermission = await _recorder.hasPermission();
    if (!hasMicPermission) {
      debugPrint('마이크 권한이 거부되었습니다. Info.plist / AndroidManifest.xml을 확인하세요.');
      return null;
    }

    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final String recordingsDirPath = p.join(appDocDir.path, 'lecture_audio');
    await Directory(recordingsDirPath).create(recursive: true);

    final String filePath = p.join(recordingsDirPath, '$sessionId.m4a');

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: filePath,
    );

    _activeRecordingFilePath = filePath;
    _recordingStartedAt = DateTime.now();
    isRecording = true;
    return filePath;
  }

  /// 녹음 시작 이후 경과 시간(ms) — 손필기 획(NormalizedStroke.audioStartMs) 타임스탬프 기록용
  int get currentRecordingElapsedMs {
    if (!isRecording || _recordingStartedAt == null) return 0;
    return DateTime.now().difference(_recordingStartedAt!).inMilliseconds;
  }

  /// 2. 실기기 마이크 녹음 종료 및 Gemini 전사용 바이트(Uint8List) 반환
  Future<({String? filePath, Uint8List? audioBytes, int durationMs})>
      stopHardwareLectureRecording() async {
    if (!isRecording) {
      return (filePath: null, audioBytes: null, durationMs: 0);
    }

    final int elapsedMs = currentRecordingElapsedMs;
    final String? savedPath = await _recorder.stop();
    isRecording = false;
    _recordingStartedAt = null;

    final String? targetPath = savedPath ?? _activeRecordingFilePath;
    if (targetPath != null && File(targetPath).existsSync()) {
      final Uint8List bytes = await File(targetPath).readAsBytes();
      return (
        filePath: targetPath,
        audioBytes: bytes,
        durationMs: elapsedMs,
      );
    }
    return (filePath: targetPath, audioBytes: null, durationMs: elapsedMs);
  }

  /// 3. 단일 강의 오디오 파일 로드 및 특정 필기 시점(targetMs) 점프 재생
  Future<void> seekAndPlaySingleAudioFile({
    required String audioFilePath,
    required int targetMs,
    double playbackSpeed = 1.0,
    required ValueChanged<int> onPositionChangedMs,
    VoidCallback? onPlaybackCompleted,
  }) async {
    await _player.setFilePath(audioFilePath);
    await _player.setSpeed(playbackSpeed);
    await _player.seek(Duration(milliseconds: targetMs));

    await _positionSub?.cancel();
    _positionSub = _player.positionStream.listen((pos) {
      onPositionChangedMs(pos.inMilliseconds);
    });

    await _playerStateSub?.cancel();
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        onPlaybackCompleted?.call();
      }
    });

    await _player.play();
  }

  /// 4. 키워드 하이라이트 오디오북 플레이리스트(List<AudiobookPlaylistTrack>)를
  /// just_audio의 ClippingAudioSource + ConcatenatingAudioSource로 변환해 무공백 연속 재생!
  Future<void> startHardwareAudiobookPlaylist({
    required String audioFilePath,
    required List<AudiobookPlaylistTrack> tracks,
    bool loopPlaylist = true,
    double playbackSpeed = 1.0,
    required void Function(int trackIndex, int globalAudioPositionMs)
        onTrackOrPositionUpdated,
  }) async {
    if (tracks.isEmpty) return;

    final List<AudioSource> clippedChildren = tracks.map((track) {
      return ClippingAudioSource(
        child: AudioSource.file(audioFilePath),
        start: Duration(milliseconds: track.effectiveStartMs),
        end: Duration(milliseconds: track.effectiveEndMs),
        tag: track,
      );
    }).toList();

    final ConcatenatingAudioSource playlistSource = ConcatenatingAudioSource(
      useLazyPreparation: true,
      children: clippedChildren,
    );

    await _player.setAudioSource(
      playlistSource,
      initialIndex: 0,
      initialPosition: Duration.zero,
    );
    await _player.setLoopMode(loopPlaylist ? LoopMode.all : LoopMode.off);
    await _player.setSpeed(playbackSpeed);

    await _positionSub?.cancel();
    _positionSub = _player.positionStream.listen((clipRelativePos) {
      final int idx = (_player.currentIndex ?? 0).clamp(0, tracks.length - 1);
      final AudiobookPlaylistTrack activeTrack = tracks[idx];
      final int globalMs =
          activeTrack.effectiveStartMs + clipRelativePos.inMilliseconds;
      onTrackOrPositionUpdated(idx, globalMs);
    });

    await _currentIndexSub?.cancel();
    _currentIndexSub = _player.currentIndexStream.listen((idx) {
      if (idx == null || idx < 0 || idx >= tracks.length) return;
      final AudiobookPlaylistTrack activeTrack = tracks[idx];
      onTrackOrPositionUpdated(idx, activeTrack.effectiveStartMs);
    });

    await _player.play();
  }

  /// 5. 배속 변경 (1.0x / 1.25x / 1.5x / 2.0x)
  Future<void> setPlaybackSpeed(double speed) async {
    await _player.setSpeed(speed.clamp(0.5, 2.5));
  }

  /// 6. 일시정지 / 재개 / 리소스 해제
  Future<void> pause() => _player.pause();

  Future<void> resume() => _player.play();

  Future<void> dispose() async {
    await _positionSub?.cancel();
    await _currentIndexSub?.cancel();
    await _playerStateSub?.cancel();
    await _recorder.dispose();
    await _player.dispose();
  }
}

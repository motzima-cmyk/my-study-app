import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'study_models.dart';

/// ============================================================================
/// [Repositories Module] 오프라인 우선 로컬 SQLite(sqflite) + Supabase Realtime 양방향 CRDT 동기화 저장소
/// 파일 경로: lib/repositories/study_sync_repository.dart (또는 lib/study_sync_repository.dart)
/// ============================================================================

/// ============================================================================
/// 3. 오프라인 우선 로컬 SQLite(sqflite) + Supabase Realtime 양방향 동기화 저장소
/// ============================================================================

class StudySyncRepository {
  final String deviceId;
  Database? _localDb;
  RealtimeChannel? _annotationChannel;
  final List<Map<String, dynamic>> _memoryOutbox = [];

  StudySyncRepository({required this.deviceId});

  Future<void> initLocalSqlite() async {
    try {
      final dbDir = await getDatabasesPath();
      final dbPath = p.join(dbDir, 'ai_study_note_sync.db');

      _localDb = await openDatabase(
        dbPath,
        version: 3,
        onCreate: (db, version) async {
          await _createTables(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          await _createTables(db);
        },
      );
    } catch (e) {
      debugPrint('로컬 SQLite 초기화 실패 (메모리 캐시로 대체 동작): $e');
    }
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_folders (
        id TEXT PRIMARY KEY,
        subject_name TEXT,
        sub_topic_summary TEXT,
        doc_type_badge TEXT,
        keywords TEXT,
        doc_count INTEGER,
        updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_documents (
        id TEXT PRIMARY KEY,
        folder_id TEXT,
        file_name TEXT,
        sub_topic TEXT,
        doc_type TEXT,
        ai_summary TEXT,
        extracted_exam_date TEXT,
        read_count INTEGER,
        updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_annotations (
        doc_id TEXT,
        page_number INTEGER,
        strokes_json TEXT,
        masks_json TEXT,
        deleted_ids TEXT,
        updated_at TEXT,
        is_dirty INTEGER DEFAULT 0,
        PRIMARY KEY (doc_id, page_number)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_study_cards (
        card_id TEXT PRIMARY KEY,
        doc_id TEXT,
        page_number INTEGER,
        card_json TEXT,
        updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_audio_sessions (
        session_id TEXT PRIMARY KEY,
        doc_id TEXT,
        title TEXT,
        total_duration_ms INTEGER,
        ai_lecture_summary TEXT,
        exam_highlights_json TEXT,
        segments_json TEXT,
        updated_at TEXT
      )
    ''');
  }

  SupabaseClient? get _supabaseOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<bool> saveAudioSession(LectureAudioSession session) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    if (_localDb != null) {
      await _localDb!.insert(
        'local_audio_sessions',
        {
          'session_id': session.sessionId,
          'doc_id': session.docId,
          'title': session.title,
          'total_duration_ms': session.totalDurationMs,
          'ai_lecture_summary': session.aiLectureSummary,
          'exam_highlights_json': jsonEncode(session.examHighlightPoints),
          'segments_json':
              jsonEncode(session.segments.map((s) => s.toJson()).toList()),
          'updated_at': nowIso,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final client = _supabaseOrNull;
    if (client == null) return false;
    try {
      await client.from('audio_sessions').upsert(session.toJson());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> saveStudyCard(WrongAnswerStudyCard card) async {
    if (_localDb != null) {
      await _localDb!.insert(
        'local_study_cards',
        {
          'card_id': card.cardId,
          'doc_id': card.docId,
          'page_number': card.pageNumber,
          'card_json': jsonEncode(card.toJson()),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final client = _supabaseOrNull;
    if (client == null) return false;
    try {
      await client.from('study_cards').upsert(card.toJson());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> saveFolderAndClassifiedDocument({
    required AutoFolderItem folder,
    required String docId,
    required String fileName,
    required DocumentClassificationResult classification,
    required int readCount,
    Uint8List? pdfBytes,
  }) async {
    if (_localDb != null) {
      await _localDb!.insert(
        'local_folders',
        {
          'id': folder.id,
          'subject_name': folder.subjectName,
          'sub_topic_summary': folder.subTopicSummary,
          'doc_type_badge': folder.docTypeBadge,
          'keywords': jsonEncode(folder.keywords),
          'doc_count': folder.docCount,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await _localDb!.insert(
        'local_documents',
        {
          'id': docId,
          'folder_id': folder.id,
          'file_name': fileName,
          'sub_topic': classification.subTopic,
          'doc_type': classification.docType,
          'ai_summary': classification.summary,
          'extracted_exam_date': classification.extractedExamDate ?? '',
          'read_count': readCount,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final client = _supabaseOrNull;
    if (client == null) return false;

    try {
      String? storagePath;
      if (pdfBytes != null) {
        storagePath = 'pdfs/$docId/$fileName';
        await client.storage.from('study_pdfs').uploadBinary(
              storagePath,
              pdfBytes,
              fileOptions: const FileOptions(upsert: true),
            );
      }

      await client.from('folders').upsert(folder.toJson());
      await client.from('documents').upsert({
        'id': docId,
        'folder_id': folder.id,
        'file_name': fileName,
        'storage_path': storagePath,
        'sub_topic': classification.subTopic,
        'doc_type': classification.docType,
        'ai_summary': classification.summary,
        'extracted_exam_date': classification.extractedExamDate,
        'read_count': readCount,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      return true;
    } catch (e) {
      debugPrint('클라우드 문서 메타데이터 업서트 보류 (오프라인 큐 저장): $e');
      return false;
    }
  }

  Future<bool> savePageAnnotations(PageAnnotationSnapshot snapshot) async {
    final strokesJsonStr =
        jsonEncode(snapshot.strokes.map((s) => s.toJson()).toList());
    final masksJsonStr =
        jsonEncode(snapshot.masks.map((m) => m.toJson()).toList());
    final deletedJsonStr = jsonEncode(snapshot.deletedIds.toList());
    final nowIso = DateTime.now().toUtc().toIso8601String();

    if (_localDb != null) {
      await _localDb!.insert(
        'local_annotations',
        {
          'doc_id': snapshot.docId,
          'page_number': snapshot.pageNumber,
          'strokes_json': strokesJsonStr,
          'masks_json': masksJsonStr,
          'deleted_ids': deletedJsonStr,
          'updated_at': nowIso,
          'is_dirty': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final client = _supabaseOrNull;
    final payload = {
      'doc_id': snapshot.docId,
      'page_number': snapshot.pageNumber,
      'strokes_json': snapshot.strokes.map((s) => s.toJson()).toList(),
      'masks_json': snapshot.masks.map((m) => m.toJson()).toList(),
      'deleted_ids': snapshot.deletedIds.toList(),
      'updated_device': deviceId,
      'updated_at': nowIso,
    };

    if (client == null) {
      _memoryOutbox.add(payload);
      return false;
    }

    try {
      await client.from('annotations').upsert(payload);
      if (_localDb != null) {
        await _localDb!.update(
          'local_annotations',
          {'is_dirty': 0},
          where: 'doc_id = ? AND page_number = ?',
          whereArgs: [snapshot.docId, snapshot.pageNumber],
        );
      }
      return true;
    } catch (e) {
      debugPrint('오프라인 상태 감지 — 로컬 큐에 필기 변경사항 보관: $e');
      _memoryOutbox.add(payload);
      return false;
    }
  }

  Future<PageAnnotationSnapshot?> loadAndMergePageAnnotations({
    required String docId,
    required int pageNumber,
  }) async {
    PageAnnotationSnapshot? localSnap;

    if (_localDb != null) {
      final rows = await _localDb!.query(
        'local_annotations',
        where: 'doc_id = ? AND page_number = ?',
        whereArgs: [docId, pageNumber],
      );
      if (rows.isNotEmpty) {
        localSnap = _parseSnapshotFromRow(docId, pageNumber, rows.first);
      }
    }

    final client = _supabaseOrNull;
    if (client != null) {
      try {
        final remoteRow = await client
            .from('annotations')
            .select()
            .eq('doc_id', docId)
            .eq('page_number', pageNumber)
            .maybeSingle();

        if (remoteRow != null) {
          final remoteSnap =
              _parseSnapshotFromRow(docId, pageNumber, remoteRow);
          return localSnap != null
              ? localSnap.mergeWith(remoteSnap)
              : remoteSnap;
        }
      } catch (e) {
        debugPrint('원격 필기 조회 실패 (로컬 SQLite 데이터 사용): $e');
      }
    }
    return localSnap;
  }

  void subscribeToDocumentRealtime({
    required String docId,
    required void Function(PageAnnotationSnapshot remoteSnapshot)
        onRemotePageUpdated,
  }) {
    final client = _supabaseOrNull;
    if (client == null) return;

    _annotationChannel?.unsubscribe();
    _annotationChannel = client
        .channel('public:annotations:$docId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'annotations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'doc_id',
            value: docId,
          ),
          callback: (payload) {
            final newRecord = payload.newRecord;
            if (newRecord.isEmpty) return;
            if (newRecord['updated_device'] == deviceId) return;

            final pageNum = (newRecord['page_number'] as num?)?.toInt() ?? 1;
            final remoteSnap =
                _parseSnapshotFromRow(docId, pageNum, newRecord);
            onRemotePageUpdated(remoteSnap);
          },
        )
        .subscribe();
  }

  Future<int> flushOfflineOutbox() async {
    final client = _supabaseOrNull;
    if (client == null) return 0;

    int flushedCount = 0;
    if (_localDb != null) {
      final dirtyRows = await _localDb!.query(
        'local_annotations',
        where: 'is_dirty = 1',
      );
      for (final row in dirtyRows) {
        try {
          final snap = _parseSnapshotFromRow(
            row['doc_id'] as String,
            (row['page_number'] as num).toInt(),
            row,
          );
          await client.from('annotations').upsert({
            'doc_id': snap.docId,
            'page_number': snap.pageNumber,
            'strokes_json': snap.strokes.map((s) => s.toJson()).toList(),
            'masks_json': snap.masks.map((m) => m.toJson()).toList(),
            'deleted_ids': snap.deletedIds.toList(),
            'updated_device': deviceId,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          });
          await _localDb!.update(
            'local_annotations',
            {'is_dirty': 0},
            where: 'doc_id = ? AND page_number = ?',
            whereArgs: [snap.docId, snap.pageNumber],
          );
          flushedCount++;
        } catch (_) {}
      }
    }
    return flushedCount;
  }

  PageAnnotationSnapshot _parseSnapshotFromRow(
    String docId,
    int pageNumber,
    Map<String, dynamic> row,
  ) {
    final rawStrokes = row['strokes_json'];
    final rawMasks = row['masks_json'];
    final rawDeleted = row['deleted_ids'];

    final List<dynamic> strokeList = rawStrokes is String
        ? (jsonDecode(rawStrokes) as List<dynamic>)
        : (rawStrokes as List<dynamic>? ?? const []);

    final List<dynamic> maskList = rawMasks is String
        ? (jsonDecode(rawMasks) as List<dynamic>)
        : (rawMasks as List<dynamic>? ?? const []);

    final List<dynamic> deletedList = rawDeleted is String
        ? (jsonDecode(rawDeleted) as List<dynamic>)
        : (rawDeleted as List<dynamic>? ?? const []);

    return PageAnnotationSnapshot(
      docId: docId,
      pageNumber: pageNumber,
      strokes: strokeList
          .map((e) => NormalizedStroke.fromJson(e as Map<String, dynamic>))
          .toList(),
      masks: maskList
          .map((e) => NormalizedMaskRect.fromJson(e as Map<String, dynamic>))
          .toList(),
      deletedIds: deletedList.map((e) => e.toString()).toSet(),
    );
  }

  void dispose() {
    _annotationChannel?.unsubscribe();
    _localDb?.close();
  }
}

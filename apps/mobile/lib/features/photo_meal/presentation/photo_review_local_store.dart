import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:path_provider/path_provider.dart';

/// Registro locale dei job gestiti (confermati o scartati) da Marco.
/// Il client non può aggiornare la riga remota: il job resta needs_review
/// sul server per sempre, quindi senza questo registro le proposte già
/// gestite riapparirebbero a ogni polling. Pattern file JSON come
/// `backup_storage.dart`: schema locale intoccato (resta v3).
/// Tiene anche il registro delle foto la cui cancellazione dal bucket è
/// fallita (offline): la promessa «la foto viene tolta dal cloud» resta
/// vera perché la delete viene ritentata ai giri successivi.
abstract class PhotoReviewLocalStore {
  Future<Set<String>> handledJobIds();

  Future<void> markHandled({required String jobId, required String outcome});

  /// Riapre un job chiuso per errore (rollback quando la scrittura nel
  /// diario non riesce dopo la registrazione dell'esito).
  Future<void> unmarkHandled({required String jobId});

  /// Foto rimaste sul bucket dopo una delete fallita, da ritentare.
  Future<List<String>> pendingPhotoDeletes();

  Future<void> addPendingPhotoDelete(String storageObject);

  Future<void> removePendingPhotoDelete(String storageObject);
}

class FilePhotoReviewLocalStore implements PhotoReviewLocalStore {
  FilePhotoReviewLocalStore({Future<Directory> Function()? stateDirectory})
    : _stateDirectory = stateDirectory ?? getApplicationSupportDirectory;

  static const stateFileName = 'kal-tracker-photo-review-state.json';
  static const maximumEntries = 200;

  final Future<Directory> Function() _stateDirectory;

  @override
  Future<Set<String>> handledJobIds() async {
    final entries = await _readEntries();
    return {
      for (final entry in entries)
        if (entry['job_id'] is String) entry['job_id']! as String,
    };
  }

  @override
  Future<void> markHandled({
    required String jobId,
    required String outcome,
  }) async {
    final entries = await _readEntries();
    entries.removeWhere((entry) => entry['job_id'] == jobId);
    entries.add({
      'job_id': jobId,
      'outcome': outcome,
      'handled_at': AppTime.nowUtc().toIso8601String(),
    });
    final trimmed = entries.length > maximumEntries
        ? entries.sublist(entries.length - maximumEntries)
        : entries;
    await _writeState(handled: trimmed, pendingDeletes: await _readPending());
  }

  @override
  Future<void> unmarkHandled({required String jobId}) async {
    final entries = await _readEntries();
    entries.removeWhere((entry) => entry['job_id'] == jobId);
    await _writeState(handled: entries, pendingDeletes: await _readPending());
  }

  @override
  Future<List<String>> pendingPhotoDeletes() => _readPending();

  @override
  Future<void> addPendingPhotoDelete(String storageObject) async {
    if (storageObject.isEmpty) {
      return;
    }
    final pending = await _readPending();
    if (pending.contains(storageObject)) {
      return;
    }
    pending.add(storageObject);
    final trimmed = pending.length > maximumEntries
        ? pending.sublist(pending.length - maximumEntries)
        : pending;
    await _writeState(handled: await _readEntries(), pendingDeletes: trimmed);
  }

  @override
  Future<void> removePendingPhotoDelete(String storageObject) async {
    final pending = await _readPending();
    if (!pending.remove(storageObject)) {
      return;
    }
    await _writeState(handled: await _readEntries(), pendingDeletes: pending);
  }

  Future<void> _writeState({
    required List<Map<String, Object?>> handled,
    required List<String> pendingDeletes,
  }) async {
    final file = await _stateFile();
    await file.writeAsString(
      jsonEncode({
        'handled_jobs': handled,
        'pending_photo_deletes': pendingDeletes,
      }),
      flush: true,
    );
  }

  Future<List<Map<String, Object?>>> _readEntries() async {
    final decoded = await _readState();
    final rawEntries = decoded['handled_jobs'];
    if (rawEntries is! List) {
      return [];
    }
    return [
      for (final entry in rawEntries)
        if (entry is Map) Map<String, Object?>.from(entry),
    ];
  }

  Future<List<String>> _readPending() async {
    final decoded = await _readState();
    final rawPending = decoded['pending_photo_deletes'];
    if (rawPending is! List) {
      return [];
    }
    return [
      for (final entry in rawPending)
        if (entry is String && entry.isNotEmpty) entry,
    ];
  }

  Future<Map<String, Object?>> _readState() async {
    try {
      final file = await _stateFile();
      if (!file.existsSync()) {
        return const {};
      }
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? decoded : const {};
    } on Object {
      // File corrotto o illeggibile: si riparte da zero senza bloccare.
      return const {};
    }
  }

  Future<File> _stateFile() async {
    final directory = await _stateDirectory();
    return File('${directory.path}/$stateFileName');
  }
}

final photoReviewLocalStoreProvider = Provider<PhotoReviewLocalStore>(
  (ref) => FilePhotoReviewLocalStore(),
);

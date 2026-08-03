import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Stato persistente del motore di sync: cursore del change feed,
/// data dell'ultimo sync riuscito e mappa id remoti -> id locali
/// per le poche entità con id locale non-uuid (es. alimenti seed).
class SyncState {
  const SyncState({
    this.lastChangeId = 0,
    this.lastSyncAt,
    this.remoteToLocalIds = const {},
  });

  const SyncState.empty()
    : lastChangeId = 0,
      lastSyncAt = null,
      remoteToLocalIds = const {};

  final int lastChangeId;
  final DateTime? lastSyncAt;
  final Map<String, String> remoteToLocalIds;

  SyncState copyWith({
    int? lastChangeId,
    DateTime? lastSyncAt,
    Map<String, String>? remoteToLocalIds,
  }) => SyncState(
    lastChangeId: lastChangeId ?? this.lastChangeId,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    remoteToLocalIds: remoteToLocalIds ?? this.remoteToLocalIds,
  );
}

/// File JSON nello stesso stile di [FileBackupStorage]: lettura difensiva,
/// scrittura con flush che ingoia gli errori.
class SyncStateStore {
  SyncStateStore({Future<Directory> Function()? stateDirectory})
    : _stateDirectory = stateDirectory ?? getApplicationSupportDirectory;

  static const String stateFileName = 'kal-tracker-sync-state.json';

  final Future<Directory> Function() _stateDirectory;

  Future<SyncState> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return const SyncState.empty();
      }
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        return const SyncState.empty();
      }
      final lastChangeId = decoded['last_change_id'];
      final lastSyncAt = decoded['last_sync_at'];
      final idMap = decoded['id_map'];
      return SyncState(
        lastChangeId: lastChangeId is int && lastChangeId >= 0
            ? lastChangeId
            : 0,
        lastSyncAt: lastSyncAt is String
            ? DateTime.tryParse(lastSyncAt)?.toUtc()
            : null,
        remoteToLocalIds: idMap is Map
            ? {
                for (final entry in idMap.entries)
                  if (entry.key is String && entry.value is String)
                    entry.key as String: entry.value as String,
              }
            : const {},
      );
    } on Object {
      return const SyncState.empty();
    }
  }

  Future<void> write(SyncState state) async {
    try {
      final file = await _file();
      file.writeAsStringSync(
        jsonEncode({
          'last_change_id': state.lastChangeId,
          'last_sync_at': state.lastSyncAt?.toUtc().toIso8601String(),
          'id_map': state.remoteToLocalIds,
        }),
        flush: true,
      );
    } on Object {
      return;
    }
  }

  Future<File> _file() async {
    final directory = await _stateDirectory();
    return File('${directory.path}/$stateFileName');
  }
}

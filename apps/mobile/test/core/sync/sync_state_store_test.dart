import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/sync/sync_state_store.dart';

void main() {
  late Directory tempDir;
  late SyncStateStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kal-sync-state');
    store = SyncStateStore(stateDirectory: () async => tempDir);
  });

  tearDown(() => tempDir.delete(recursive: true));

  test('parte vuoto e fa il roundtrip di cursore, data e mappa id', () async {
    var state = await store.read();
    expect(state.lastChangeId, 0);
    expect(state.lastSyncAt, isNull);
    expect(state.remoteToLocalIds, isEmpty);

    final syncedAt = DateTime.utc(2026, 8, 3, 10, 30);
    await store.write(
      SyncState(
        lastChangeId: 42,
        lastSyncAt: syncedAt,
        remoteToLocalIds: const {'remoto-1': 'seed-oats'},
      ),
    );

    state = await store.read();
    expect(state.lastChangeId, 42);
    expect(state.lastSyncAt, syncedAt);
    expect(state.remoteToLocalIds, {'remoto-1': 'seed-oats'});
  });

  test('un file corrotto torna allo stato vuoto senza esplodere', () async {
    final file = File('${tempDir.path}/${SyncStateStore.stateFileName}');
    file.writeAsStringSync('{non è json');

    final state = await store.read();
    expect(state.lastChangeId, 0);
    expect(state.lastSyncAt, isNull);
  });
}

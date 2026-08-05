import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/gym_import/data/gym_tracker_importer.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

import 'gym_fixtures.dart';

/// Il punto di giunzione fra due pezzi scritti in parallelo.
///
/// L'importer riempie la coda di sincronizzazione, il gateway la svuota, e
/// nessuno dei due sa com'è fatto l'altro: i test dell'uno costruiscono i
/// payload a mano, quelli dell'altro li consumano a mano. Se i nomi dei campi
/// o la forma dei figli annidati divergessero, entrambe le suite resterebbero
/// verdi e il disallineamento si vedrebbe solo al primo push contro Supabase —
/// dove il prezzo è una riga di outbox che si pianta o, peggio, un dato che
/// non arriva.
///
/// Qui la coda vera dell'importer passa davvero per il mapper vero.
void main() {
  setUpAll(AppTime.initialize);

  Future<(AppDatabase, List<SyncOutboxData>)> importaConCoda() async {
    final database = AppDatabase(NativeDatabase.memory());
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    await GymTrackerImporter(database).importExport(
      profileId: profile.id,
      export: loadGymExport(),
      firestoreDump: loadFirestoreDump(),
      firestoreUserId: fixtureFirestoreUserId,
      enqueueSync: true,
    );
    final coda = await database.select(database.syncOutbox).get();
    return (database, coda);
  }

  test('ogni riga accodata dall import è mappabile dal gateway', () async {
    final (database, coda) = await importaConCoda();
    addTearDown(database.close);

    expect(coda, isNotEmpty, reason: 'l import non ha accodato niente');

    final perTipo = <String, int>{};
    for (final riga in coda) {
      perTipo.update(riga.entityType, (n) => n + 1, ifAbsent: () => 1);

      final mutation = SyncMutation(
        mutationId: riga.id,
        entityType: riga.entityType,
        entityId: riga.entityId,
        operation: riga.operation,
        payload: jsonDecode(riga.payloadJson) as Map<String, Object?>,
      );

      // Il mapper alza SyncGatewayException sui tipi che non conosce: qui
      // deve conoscerli tutti, ed è esattamente ciò che l'esecuzione in
      // parallelo non poteva garantire.
      late final MappedMutation mapped;
      expect(
        () => mapped = SyncPushMapper.map(mutation),
        returnsNormally,
        reason:
            'il gateway non sa mappare «${riga.entityType}» '
            'prodotto dall import',
      );
      expect(
        mapped.ops,
        isNotEmpty,
        reason:
            '«${riga.entityType}» si mappa in zero operazioni: '
            'la coda si svuoterebbe senza che il server riceva niente',
      );
    }

    // I cinque tipi che l'import genera davvero sui dati reali.
    expect(perTipo.keys.toSet(), {
      'exercise',
      'routine',
      'workout',
      'workout_profile_stats',
      'body_measurement',
    });
  });

  test('la sessione con i figli annidati arriva intera al gateway', () async {
    final (database, coda) = await importaConCoda();
    addTearDown(database.close);

    final righeWorkout = coda.where((r) => r.entityType == 'workout');
    expect(righeWorkout, hasLength(29));

    // Una sessione con esercizi e serie: è la forma che il mapper deve
    // riconoscere, e quella su cui un disallineamento farebbe più danno
    // perché perderebbe i figli senza perdere il padre.
    var conFigli = 0;
    for (final riga in righeWorkout) {
      final payload = jsonDecode(riga.payloadJson) as Map<String, Object?>;
      final esercizi = payload['exercises'];
      if (esercizi is! List || esercizi.isEmpty) continue;
      conFigli++;

      final mapped = SyncPushMapper.map(
        SyncMutation(
          mutationId: riga.id,
          entityType: riga.entityType,
          entityId: riga.entityId,
          operation: riga.operation,
          payload: payload,
        ),
      );

      // Padre più figli: un solo op vorrebbe dire che esercizi e serie sono
      // stati silenziosamente ignorati.
      expect(
        mapped.ops.length,
        greaterThan(1),
        reason:
            'la sessione ${riga.entityId} ha ${esercizi.length} esercizi '
            'ma si mappa in ${mapped.ops.length} operazione/i',
      );
    }

    expect(conFigli, 21, reason: 'le sessioni con esercizi dettagliati');
  });
}

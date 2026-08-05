import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/gym_import/data/gym_tracker_importer.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/weekly_plan/data/workout_plan_repository.dart';

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
/// Qui la coda vera dell'importer passa davvero per il mapper vero. Da quando
/// `enqueueSync` è acceso di serie questo test è anche il collaudo di quella
/// decisione: è l'unico posto in cui si vede cosa uscirebbe davvero dal
/// telefono di Marco.
void main() {
  setUpAll(AppTime.initialize);

  Future<(AppDatabase, String, List<SyncOutboxData>)> importaConCoda() async {
    final database = AppDatabase(NativeDatabase.memory());
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    // `enqueueSync` NON viene passato: si collauda il valore di serie, che è
    // quello con cui l'import gira sul telefono. Se qualcuno lo rispegnesse,
    // qui la coda tornerebbe vuota e il test cadrebbe subito.
    await GymTrackerImporter(database).importExport(
      profileId: profile.id,
      export: loadGymExport(),
      firestoreDump: loadFirestoreDump(),
      firestoreUserId: fixtureFirestoreUserId,
    );
    final coda = await database.select(database.syncOutbox).get();
    return (database, profile.id, coda);
  }

  SyncMutation mutationDi(SyncOutboxData riga) => SyncMutation(
    mutationId: riga.id,
    entityType: riga.entityType,
    entityId: riga.entityId,
    operation: riga.operation,
    payload: jsonDecode(riga.payloadJson) as Map<String, Object?>,
  );

  /// Tutte le righe che il gateway manderebbe al server, tabella per tabella.
  List<({String table, Map<String, Object?> row})> righeRemote(
    Iterable<SyncOutboxData> coda,
  ) {
    final righe = <({String table, Map<String, Object?> row})>[];
    for (final riga in coda) {
      for (final op in SyncPushMapper.map(mutationDi(riga)).ops) {
        switch (op) {
          case RemoteUpsert():
            for (final row in op.rows) {
              righe.add((table: op.table, row: row));
            }
          case RemotePatch():
            righe.add((table: op.table, row: {'id': op.id, ...op.values}));
          case RemoteChildrenSwap():
            for (final row in op.rows) {
              righe.add((table: op.table, row: row));
            }
        }
      }
    }
    return righe;
  }

  test('ogni riga accodata dall import è mappabile dal gateway', () async {
    final (database, _, coda) = await importaConCoda();
    addTearDown(database.close);

    expect(coda, isNotEmpty, reason: 'l import non ha accodato niente');

    final perTipo = <String, int>{};
    for (final riga in coda) {
      perTipo.update(riga.entityType, (n) => n + 1, ifAbsent: () => 1);

      // Il mapper alza SyncGatewayException sui tipi che non conosce: qui
      // deve conoscerli tutti, ed è esattamente ciò che l'esecuzione in
      // parallelo non poteva garantire.
      late final MappedMutation mapped;
      expect(
        () => mapped = SyncPushMapper.map(mutationDi(riga)),
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

  test('un tipo sconosciuto ferma la coda invece di svuotarla', () async {
    // La contromisura che rende sicuro accendere `enqueueSync`: se un tipo
    // non fosse mappato, la riga NON verrebbe scartata come inviata. Il test
    // serve a due cose insieme — dimostrare che il blocco esiste, e che
    // nessuno dei tipi dell'import ci finisce (lo verifica il test sopra).
    MappedMutation errore() => SyncPushMapper.map(
      const SyncMutation(
        mutationId: '11111111-1111-4111-8111-111111111111',
        entityType: 'tipo_che_non_esiste',
        entityId: 'x',
        operation: 'upsert',
        payload: {},
      ),
    );
    expect(
      errore,
      throwsA(
        isA<SyncGatewayException>().having(
          (error) => error.retryable,
          'ritentabile',
          isTrue,
        ),
      ),
    );
  });

  test('la sessione con i figli annidati arriva intera al gateway', () async {
    final (database, _, coda) = await importaConCoda();
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

      final mapped = SyncPushMapper.map(mutationDi(riga));

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

  test('tutte e quattro le famiglie di figli annidati escono', () async {
    final (database, _, coda) = await importaConCoda();
    addTearDown(database.close);

    final tabelle = righeRemote(coda).map((riga) => riga.table).toSet();

    // Le tredici tabelle della v6 non servono tutte all'import (le fixture non
    // hanno dolori né circuiti registrati in sessione), ma queste sì: se una
    // sparisse, l'import avrebbe scritto nel telefono qualcosa che il server
    // non vedrà mai.
    expect(tabelle, containsAll(<String>{'exercises', 'routines', 'workouts'}));
    expect(tabelle, contains('routine_exercises'));
    expect(tabelle, contains('routine_interval_segments'));
    expect(tabelle, contains('workout_exercises'));
    expect(tabelle, contains('workout_sets'));
    expect(tabelle, contains('workout_profile_stats'));
    expect(tabelle, contains('workout_achievements'));
    expect(tabelle, contains('routine_weekly_plan'));
    expect(tabelle, contains('body_measurements'));
  });

  test('nessun id non-uuid arriva a una colonna uuid', () async {
    final (database, _, coda) = await importaConCoda();
    addTearDown(database.close);

    // Sul server ogni `*_id` è di tipo uuid — l'unica eccezione è
    // `external_id`, che è testo apposta perché conserva l'id di Gym in
    // chiaro (compresi gli slug `cd-*` dei preset di defaticamento). Un id
    // non derivato che scivolasse in una colonna uuid sarebbe un 22P02
    // permanente: la mutation verrebbe scartata e il dato perso.
    var controllati = 0;
    for (final riga in righeRemote(coda)) {
      for (final campo in riga.row.entries) {
        final chiave = campo.key;
        if (chiave != 'id' && !chiave.endsWith('_id')) continue;
        if (chiave == 'external_id') continue;
        final valore = campo.value;
        if (valore == null) continue;
        controllati++;
        expect(
          valore,
          isA<String>().having(SyncIds.isUuid, 'è un uuid', isTrue),
          reason: '${riga.table}.$chiave vale «$valore»',
        );
      }
    }
    expect(controllati, greaterThan(1000), reason: 'il giro ha guardato poco');
  });

  test('l esercizio citato da una serie è lo stesso che viaggia', () async {
    final (database, _, coda) = await importaConCoda();
    addTearDown(database.close);

    final righe = righeRemote(coda);
    final esercizi = {
      for (final riga in righe)
        if (riga.table == 'exercises') riga.row['id'] as String,
    };
    // Gli slug `cd-*` diventano uuid v5 in DUE posti indipendenti: nella riga
    // del catalogo (dall'entityId della mutation) e nel riferimento della
    // riga di allenamento (dal payload del figlio). Se le due derivazioni
    // divergessero il server risponderebbe 23503 e la sessione resterebbe
    // bloccata in testa alla coda per sempre.
    final riferimenti = {
      for (final riga in righe)
        if (riga.table == 'workout_exercises' ||
            riga.table == 'routine_exercises')
          riga.row['exercise_ref_id'] as String,
    };

    expect(riferimenti, isNotEmpty);
    expect(
      riferimenti.difference(esercizi),
      isEmpty,
      reason: 'ci sono riferimenti a esercizi che nessuna riga porta al server',
    );
  });

  test('le righe di una tabella non si rubano il mutation id', () async {
    final (database, _, coda) = await importaConCoda();
    addTearDown(database.close);

    // Il ledger remoto impone unique(owner_id, entity_type, mutation_id) e le
    // tabelle unique(owner_id, last_mutation_id): due righe della stessa
    // tabella con lo stesso `last_mutation_id` sarebbero un 23505, cioè
    // l'intera mutation respinta.
    final visti = <String, Set<String>>{};
    for (final riga in righeRemote(coda)) {
      final mutationId = riga.row['last_mutation_id'];
      if (mutationId is! String) continue;
      final perTabella = visti.putIfAbsent(riga.table, () => <String>{});
      expect(
        perTabella.add(mutationId),
        isTrue,
        reason: '${riga.table}: $mutationId compare due volte',
      );
    }
    expect(visti.keys, isNotEmpty);
  });

  test('quello che serve prima viaggia prima', () async {
    final (database, _, coda) = await importaConCoda();
    addTearDown(database.close);

    // La coda si svuota in ordine e si ferma al primo errore. Le chiavi
    // esterne del server pretendono quindi che il catalogo esercizi e le
    // schede siano già passati quando arrivano le sessioni che li citano:
    // 23503 è ritentabile, ma una coda che si sblocca solo al giro dopo è
    // comunque una sincronizzazione che non finisce mai al primo colpo.
    int ultimo(String tipo) =>
        coda.lastIndexWhere((riga) => riga.entityType == tipo);
    int primo(String tipo) =>
        coda.indexWhere((riga) => riga.entityType == tipo);

    expect(ultimo('exercise'), lessThan(primo('routine')));
    expect(ultimo('routine'), lessThan(primo('workout')));
    // Il piano settimanale viaggia dentro le statistiche di profilo e cita le
    // schede: anche lui deve arrivare dopo.
    expect(ultimo('routine'), lessThan(primo('workout_profile_stats')));
  });

  test('la settimana importata e quella composta a mano sono la stessa '
      'riga', () async {
    final (database, profileId, coda) = await importaConCoda();
    addTearDown(database.close);

    final giorni = await database.select(database.routineWeeklyPlan).get();
    expect(giorni, hasLength(5));
    for (final giorno in giorni) {
      // L'importer deriva i suoi id con lo stesso sale del comporre-settimana
      // di Palestra. Se le due derivazioni divergessero, scegliere il martedì
      // a mano dopo un import romperebbe la UNIQUE (profile_id, weekday) — e
      // su due dispositivi offline creerebbe due righe per lo stesso giorno.
      expect(
        giorno.id,
        WorkoutPlanRepository.dayId(profileId, giorno.weekday),
        reason: 'giorno ${giorno.weekday}',
      );
    }

    // E gli id che escono verso il server coincidono: la settimana scritta a
    // mano sovrascrive quella importata invece di affiancarla.
    final remoti = {
      for (final riga in righeRemote(coda))
        if (riga.table == 'routine_weekly_plan') riga.row['id'] as String,
    };
    expect(remoti, {for (final giorno in giorni) SyncIds.remoteId(giorno.id)});
  });
}

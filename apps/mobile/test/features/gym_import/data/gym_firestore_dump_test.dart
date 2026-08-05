import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/gym_import/data/gym_firestore_dump.dart';

import '../gym_fixtures.dart';

void main() {
  setUpAll(AppTime.initialize);

  test('sceglie da solo l utente che ha uno storico', () {
    final dump = GymFirestoreDump.read(loadFirestoreDump());

    expect(dump.userId, fixtureFirestoreUserId);
    expect(dump.exerciseExtras, hasLength(308));
    expect(dump.routineExtras, hasLength(14));
    expect(dump.workoutExtras, hasLength(29));
    // Gli altri due UID hanno solo schede di esempio: ignorarli in silenzio
    // sarebbe indistinguibile dal non averli visti.
    expect(dump.warnings.where((w) => w.contains('3 utenti')), hasLength(1));
  });

  test('un utente inesistente è un errore, non un dump vuoto', () {
    expect(
      () => GymFirestoreDump.read(loadFirestoreDump(), userId: 'nessuno'),
      throwsA(isA<FormatException>()),
    );
  });

  test('porta le prescrizioni che l export non ha', () {
    final dump = GymFirestoreDump.read(loadFirestoreDump());
    final total = dump.routineExtras.values
        .map((routine) => routine.prescriptions.length)
        .fold<int>(0, (sum, value) => sum + value);

    expect(total, 121);
    final allenamentoA =
        dump.routineExtras['1deb6481-a724-4e59-8aa6-a136245813ff']!;
    final curl =
        allenamentoA.prescriptions['0eb43200-178c-4b9e-aa9b-14591ade1506']!;
    expect(curl.sets, 4);
    expect(curl.reps, 12);
    expect(curl.restSec, 30);
    expect(curl.durationSec, isNull);
  });

  test('porta i blocchi a tempo delle tre schede che li hanno', () {
    final dump = GymFirestoreDump.read(loadFirestoreDump());
    final withSegments = dump.routineExtras.entries
        .where((entry) => entry.value.segments.isNotEmpty)
        .toList();

    expect(withSegments, hasLength(3));
    final elastici =
        dump.routineExtras['bca2ff3e-1e21-4d84-a759-f8c1d9b55c15']!.segments;
    expect(elastici.map((s) => s.segmentIndex), [0, 1]);
    expect(elastici.first.startIdx, 8);
    expect(elastici.first.endIdx, 13);
    expect(elastici.first.workSec, 40);
    expect(elastici.first.restSec, 30);
    expect(elastici.first.rounds, 3);
  });

  test('porta pause, durate registrate e marcatori dei circuiti', () {
    final dump = GymFirestoreDump.read(loadFirestoreDump());

    final aperta = dump.workoutExtras['019523c1-0d72-4bfc-a124-2656cdccc4a1']!;
    expect(aperta.finalDurationSeconds, 1929475);
    expect(aperta.accumulatedPauseSeconds, 0);

    final conPausa =
        dump.workoutExtras['4607943c-df58-4993-9d52-9aae4571b278']!;
    expect(conPausa.accumulatedPauseSeconds, 885);
    expect(conPausa.finalDurationSeconds, 1329);

    // L'unico marcatore di blocco a tempo dello storico, ed è un parziale:
    // se completato e parziale fossero una colonna sola andrebbe perso.
    final conParziale =
        dump.workoutExtras['abc6a8bb-3759-4c51-abba-2442880ac390']!;
    expect(conParziale.partialSegments, {0});
    expect(conParziale.completedSegments, isEmpty);
    expect(conParziale.healthSyncState, 'synced');
  });

  test('senza dump ogni ricerca è vuota e non esplode', () {
    final dump = GymFirestoreDump.absent();

    expect(dump.isPresent, isFalse);
    expect(dump.routineExtras['qualunque'], isNull);
    expect(dump.workoutExtras['qualunque'], isNull);
  });
}

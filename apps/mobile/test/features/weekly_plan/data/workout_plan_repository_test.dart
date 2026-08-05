import 'dart:convert';

// `Value` di drift serve alle companion; i matcher vengono da flutter_test,
// quindi l'import di drift nasconde quelli che collidono (`isNull`).
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/weekly_plan/data/workout_plan_repository.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_week.dart';

void main() {
  late AppDatabase database;
  late LocalProfile profile;
  late WorkoutPlanRepository repository;

  final now = DateTime.utc(2026, 8, 4, 9);

  Future<void> addRoutine(
    String id,
    String name, {
    bool isCircuit = false,
    int mainExercises = 0,
    bool deleted = false,
  }) async {
    await database
        .into(database.routines)
        .insert(
          RoutinesCompanion.insert(
            id: id,
            profileId: profile.id,
            name: name,
            isCircuit: Value(isCircuit),
            createdAt: now,
            updatedAt: now,
            deletedAt: Value(deleted ? now : null),
          ),
        );
    for (var position = 0; position < mainExercises; position++) {
      await database
          .into(database.routineExercises)
          .insert(
            RoutineExercisesCompanion.insert(
              id: '$id-ex-$position',
              routineId: id,
              block: 'main',
              position: position,
              exerciseRefId: 'exercise-$position',
              exerciseNameSnapshot: 'Esercizio $position',
            ),
          );
    }
  }

  Future<void> planDay(int weekday, {String? routineId, String? snapshot}) =>
      database
          .into(database.routineWeeklyPlan)
          .insert(
            RoutineWeeklyPlanCompanion.insert(
              id: 'rwp-$weekday',
              profileId: profile.id,
              weekday: weekday,
              routineId: Value(routineId),
              // Il CHECK del database pretende che l'id esterno coincida con la
              // chiave esterna quando c'è: sono lo stesso identificatore.
              routineExternalId: Value(routineId),
              routineNameSnapshot: Value(snapshot),
              updatedAt: now,
            ),
          );

  /// Una sessione chiusa: il database ne ammette UNA sola aperta per profilo
  /// (`idx_workouts_one_active`), quindi lo storico va chiuso.
  Future<void> addWorkout(String id, DateTime startedAt) => database
      .into(database.workouts)
      .insert(
        WorkoutsCompanion.insert(
          id: id,
          profileId: profile.id,
          startedAt: startedAt,
          endedAt: Value(startedAt.add(const Duration(minutes: 50))),
          createdAt: now,
          updatedAt: now,
        ),
      );

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profile = await LocalProfileRepository(database).getOrCreateMarco();
    repository = WorkoutPlanRepository(database);
  });

  tearDown(() => database.close());

  test(
    'la settimana torna in ordine di giorno, con gli esercizi contati',
    () async {
      await addRoutine('routine-gambe', 'Gambe', mainExercises: 5);
      await addRoutine('routine-hiit', 'Circuito', isCircuit: true);
      await planDay(5, routineId: 'routine-hiit', snapshot: 'Circuito');
      await planDay(2, routineId: 'routine-gambe', snapshot: 'Gambe');

      final workouts = await repository.plannedWorkouts(profile.id);

      expect(workouts.map((workout) => workout.weekday), [2, 5]);
      expect(workouts.first.routineName, 'Gambe');
      expect(workouts.first.exerciseCount, 5);
      expect(workouts.first.isCircuit, isFalse);
      expect(workouts.first.isMissing, isFalse);
      expect(workouts.last.isCircuit, isTrue);
      expect(workouts.last.exerciseCount, 0);
    },
  );

  test('la scheda cancellata lascia il giorno e il suo nome', () async {
    // Nell'export di Gym succede davvero: un giorno punta a una scheda che
    // non esiste più. Il giorno resta, ma non c'è niente da avviare.
    await addRoutine('routine-vecchia', 'Vecchia', deleted: true);
    await planDay(3, routineId: 'routine-vecchia', snapshot: 'Vecchia');

    final workouts = await repository.plannedWorkouts(profile.id);

    expect(workouts.single.routineName, 'Vecchia');
    expect(workouts.single.isMissing, isTrue);
  });

  test('lo stream si aggiorna quando la settimana cambia', () async {
    await addRoutine('routine-gambe', 'Gambe', mainExercises: 2);
    final emissions = <List<PlannedWorkout>>[];
    final subscription = repository
        .watchPlannedWorkouts(profile.id)
        .listen(emissions.add);
    await pumpEventQueue();

    await planDay(4, routineId: 'routine-gambe', snapshot: 'Gambe');
    await pumpEventQueue();
    await subscription.cancel();

    expect(emissions.first, isEmpty);
    expect(emissions.last.single.routineName, 'Gambe');
    expect(emissions.last.single.exerciseCount, 2);
  });

  test('l’ora di allenamento è la mediana delle sessioni vere', () async {
    // Istanti UTC: d'estate a Roma sono due ore più tardi.
    await addWorkout('w-1', DateTime.utc(2026, 8, 1, 16));
    await addWorkout('w-2', DateTime.utc(2026, 8, 2, 16, 30));
    await addWorkout('w-3', DateTime.utc(2026, 8, 3, 5));

    expect(await repository.trainingHour(profile.id), 18);
  });

  test('senza sessioni non si dichiara nessun orario', () async {
    expect(await repository.trainingHour(profile.id), isNull);
  });

  // ---------------------------------------------------------------
  // Comporre la settimana
  // ---------------------------------------------------------------

  Future<List<Map<String, Object?>>> outboxPayloads() async {
    final rows = await database.select(database.syncOutbox).get();
    return [
      for (final row in rows)
        {
          'entity_type': row.entityType,
          'entity_id': row.entityId,
          ...jsonDecode(row.payloadJson) as Map<String, Object?>,
        },
    ];
  }

  test('assegnare una scheda a un giorno la mette nella settimana', () async {
    await addRoutine('routine-gambe', 'Gambe', mainExercises: 3);

    await repository.setDay(
      profileId: profile.id,
      weekday: 2,
      routineId: 'routine-gambe',
    );

    final workouts = await repository.plannedWorkouts(profile.id);
    expect(workouts.single.weekday, 2);
    expect(workouts.single.routineName, 'Gambe');
    expect(workouts.single.exerciseCount, 3);

    final row = await database.select(database.routineWeeklyPlan).getSingle();
    // Il nome viene copiato: è quello che tiene in piedi il giorno quando la
    // scheda verrà cancellata.
    expect(row.routineNameSnapshot, 'Gambe');
    expect(row.routineId, 'routine-gambe');
    expect(row.routineExternalId, 'routine-gambe');
    expect(row.id, WorkoutPlanRepository.dayId(profile.id, 2));
  });

  test('riassegnare lo stesso giorno non crea una seconda riga', () async {
    await addRoutine('routine-gambe', 'Gambe');
    await addRoutine('routine-petto', 'Petto');

    await repository.setDay(
      profileId: profile.id,
      weekday: 2,
      routineId: 'routine-gambe',
    );
    await repository.setDay(
      profileId: profile.id,
      weekday: 2,
      routineId: 'routine-petto',
    );

    // L'id del giorno è deterministico: la seconda scelta SOVRASCRIVE la
    // prima invece di sbattere contro la UNIQUE (profilo, giorno).
    final rows = await database.select(database.routineWeeklyPlan).get();
    expect(rows, hasLength(1));
    expect(rows.single.routineNameSnapshot, 'Petto');
  });

  test(
    'un giorno arrivato dal server con un altro id viene rimpiazzato',
    () async {
      // Il pull scrive la riga con l'id che gli arriva: se un dispositivo
      // vecchio ne avesse generato uno suo, l'upsert sull'id derivato
      // sbatterebbe contro la UNIQUE (profilo, giorno) e la scelta di Marco
      // andrebbe persa in silenzio (`write` non deve mai esplodere in mano
      // sua). Si toglie la riga estranea, come fa già il pull.
      await addRoutine('routine-gambe', 'Gambe');
      await planDay(2, routineId: null, snapshot: 'Arrivata da fuori');

      await repository.setDay(
        profileId: profile.id,
        weekday: 2,
        routineId: 'routine-gambe',
      );

      final rows = await database.select(database.routineWeeklyPlan).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, WorkoutPlanRepository.dayId(profile.id, 2));
      expect(rows.single.routineNameSnapshot, 'Gambe');
    },
  );

  test('togliere la scheda riporta il giorno a riposo', () async {
    await addRoutine('routine-gambe', 'Gambe');
    await repository.setDay(
      profileId: profile.id,
      weekday: 4,
      routineId: 'routine-gambe',
    );

    await repository.clearDay(profileId: profile.id, weekday: 4);

    // Riposo non è una riga con un flag: è la riga che non c'è.
    expect(await database.select(database.routineWeeklyPlan).get(), isEmpty);
    expect(await repository.plannedWorkouts(profile.id), isEmpty);
  });

  test('una scheda cancellata resta scrivibile, senza collegamento', () async {
    // È lo stato in cui l'import di Gym ha lasciato cinque giorni: il giorno
    // dice cosa c'era, ma non c'è niente da avviare.
    await addRoutine('routine-vecchia', 'Vecchia', deleted: true);

    await repository.setDay(
      profileId: profile.id,
      weekday: 6,
      routineId: 'routine-vecchia',
    );

    final row = await database.select(database.routineWeeklyPlan).getSingle();
    expect(row.routineId, isNull);
    expect(row.routineExternalId, 'routine-vecchia');
    expect(row.routineNameSnapshot, 'Vecchia');
    expect(
      (await repository.plannedWorkouts(profile.id)).single.isMissing,
      isTrue,
    );
  });

  test('una scheda che non esiste viene rifiutata, senza scrivere', () async {
    await expectLater(
      repository.setDay(
        profileId: profile.id,
        weekday: 1,
        routineId: 'mai-esistita',
      ),
      throwsA(isA<ArgumentError>()),
    );

    expect(await database.select(database.routineWeeklyPlan).get(), isEmpty);
    expect(await database.select(database.syncOutbox).get(), isEmpty);
  });

  test('un giorno fuori dalla settimana non entra nel database', () async {
    await addRoutine('routine-gambe', 'Gambe');
    expect(
      () => repository.setDay(
        profileId: profile.id,
        weekday: 8,
        routineId: 'routine-gambe',
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repository.clearDay(profileId: profile.id, weekday: 0),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('ogni modifica accoda la settimana INTERA', () async {
    await addRoutine('routine-gambe', 'Gambe');
    await addRoutine('routine-petto', 'Petto');

    await repository.setDay(
      profileId: profile.id,
      weekday: 2,
      routineId: 'routine-gambe',
    );
    await repository.setDay(
      profileId: profile.id,
      weekday: 5,
      routineId: 'routine-petto',
    );
    await repository.clearDay(profileId: profile.id, weekday: 2);

    final payloads = await outboxPayloads();
    expect(payloads, hasLength(3));
    expect(
      payloads.every((p) => p['entity_type'] == 'routine_weekly_plan'),
      isTrue,
    );
    // L'entità è la settimana, non il giorno: l'entityId è il profilo, così
    // due modifiche in fila restano due mutation dello stesso oggetto.
    expect(payloads.every((p) => p['entity_id'] == profile.id), isTrue);

    List<Object?> days(int index) => payloads[index]['days']! as List<Object?>;
    expect(days(0), hasLength(1));
    expect(days(1), hasLength(2));
    // Il martedì tolto non manda un tombstone: manda una settimana senza
    // martedì. Chi legge di là se ne accorge dall'assenza.
    expect(days(2), hasLength(1));
    expect((days(2).single as Map<String, Object?>)['weekday'], 5);
  });

  test('la chiave days c\'è anche quando la settimana si svuota', () async {
    await addRoutine('routine-gambe', 'Gambe');
    await repository.setDay(
      profileId: profile.id,
      weekday: 3,
      routineId: 'routine-gambe',
    );
    await repository.clearDay(profileId: profile.id, weekday: 3);

    final ultimo = (await outboxPayloads()).last;
    // Lista vuota e chiave assente vogliono dire cose opposte: `[]` è
    // «riposo tutti i giorni» e tombstona di là, la chiave assente
    // lascerebbe le righe remote dove sono.
    expect(ultimo.containsKey('days'), isTrue);
    expect(ultimo['days'], isEmpty);
  });

  test('togliere un giorno già di riposo non accoda niente', () async {
    await repository.clearDay(profileId: profile.id, weekday: 7);

    expect(await database.select(database.syncOutbox).get(), isEmpty);
  });

  test('la settimana accodata è mappabile dal gateway', () async {
    await addRoutine('routine-gambe', 'Gambe');
    await repository.setDay(
      profileId: profile.id,
      weekday: 2,
      routineId: 'routine-gambe',
    );

    // La stessa giunzione del test di import: la coda vera passa per il
    // mapper vero. Senza, repository e gateway resterebbero verdi ciascuno
    // per conto suo anche con i nomi dei campi sfasati.
    final riga = await database.select(database.syncOutbox).getSingle();
    final mapped = SyncPushMapper.map(
      SyncMutation(
        mutationId: riga.id,
        entityType: riga.entityType,
        entityId: riga.entityId,
        operation: riga.operation,
        payload: jsonDecode(riga.payloadJson) as Map<String, Object?>,
      ),
    );

    final swap = mapped.ops.single as RemoteChildrenSwap;
    expect(swap.table, 'routine_weekly_plan');
    expect(swap.parentColumn, 'profile_id');
    expect(swap.parentId, profile.id);
    expect(swap.rows.single['weekday'], 2);
    expect(swap.rows.single['routine_name_snapshot'], 'Gambe');
    // `routine-gambe` non è un uuid: senza derivazione la colonna uuid del
    // server risponderebbe 22P02 e il giorno non arriverebbe mai.
    expect(swap.rows.single['routine_id'], SyncIds.remoteId('routine-gambe'));
    expect(
      swap.rows.single['routine_external_id'],
      swap.rows.single['routine_id'],
    );
  });
}

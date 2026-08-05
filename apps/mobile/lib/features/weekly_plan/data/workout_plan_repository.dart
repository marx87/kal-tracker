import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart' show SyncIds;
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_week.dart';
import 'package:kal_tracker/features/weekly_plan/domain/post_workout_meal.dart';
import 'package:uuid/uuid.dart';

/// La metà «palestra» della settimana unificata: `routine_weekly_plan`,
/// giorno ISO 1-7 → scheda.
///
/// Si legge per mostrarla accanto ai pasti e per dire al pianificatore quando
/// ci si allena; si scrive dal comporre-settimana in Palestra, che è l'unico
/// posto da cui Marco decide «il martedì faccio Giorno1». Prima esisteva solo
/// la lettura perché la tabella la riempiva solo l'import di Gym.
///
/// Un giorno assente È l'informazione: significa riposo (in Firestore serviva
/// un `set()` senza merge, qui basta la riga mancante). Per questo la
/// sincronizzazione manda SEMPRE la settimana intera: il giorno tolto non ha
/// una riga da tombstonare per id, si riconosce solo dal fatto che non c'è
/// più nell'elenco.
///
/// Conseguenza da conoscere: **l'unità di conflitto è la settimana, non il
/// giorno.** Se telefono e tablet compongono giorni diversi mentre sono
/// scollegati, l'ultima settimana arrivata vince per intero e l'altra scelta
/// sparisce. È il prezzo di poter cancellare un giorno; il caso opposto —
/// mandare solo il giorno toccato — lascerebbe invece per sempre sul server i
/// giorni tolti, che è un errore silenzioso e permanente invece di uno
/// visibile e correggibile in due tocchi.
class WorkoutPlanRepository {
  WorkoutPlanRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  /// Quante sessioni si guardano per capire a che ora Marco si allena.
  /// Abbastanza da coprire un paio di mesi, poche da seguire un cambio di
  /// abitudini invece di restare ferme sul primo anno di storico.
  static const int trainingHourSample = 40;

  /// Solo il blocco principale conta come «esercizi» della scheda: il
  /// riscaldamento e il finisher si contano a parte nel modulo Palestra, e
  /// qui servirebbero solo a gonfiare un numero.
  static const String _mainBlock = 'main';

  /// Il tipo di entità con cui la settimana viaggia nella coda di
  /// sincronizzazione. Non è il nome di una riga ma della SETTIMANA INTERA:
  /// una mutation sola per profilo, che il gateway traduce in una
  /// sostituzione in blocco delle righe remote.
  static const String syncEntityType = 'routine_weekly_plan';

  final AppDatabase _database;
  final Uuid _uuid;

  /// Id della riga di un giorno: DETERMINISTICO su (profilo, giorno).
  ///
  /// È la stessa derivazione che usa l'importer di Gym per i suoi giorni:
  /// un giorno composto a mano e lo stesso giorno importato SONO la stessa
  /// riga. Serve a due cose: la UNIQUE (profile_id, weekday) non viene mai
  /// messa alla prova da un id nuovo, e due dispositivi offline che scelgono
  /// entrambi il martedì scrivono la stessa riga invece di duplicarla.
  static String dayId(String profileId, int weekday) =>
      SyncIds.derived('gym-weekly-plan', '$profileId/$weekday');

  /// La settimana degli allenamenti, dal lunedì alla domenica.
  ///
  /// La scheda cancellata non sparisce dal giorno: `routine_id` diventa NULL
  /// per la chiave esterna, ma `routine_name_snapshot` resta e il giorno
  /// continua a dire cosa c'era.
  Stream<List<PlannedWorkout>> watchPlannedWorkouts(String profileId) =>
      _query(profileId).watch().map(_workoutsFrom);

  /// Una fotografia della settimana, per comporre la richiesta del piano.
  Future<List<PlannedWorkout>> plannedWorkouts(String profileId) async =>
      _workoutsFrom(await _query(profileId).get());

  /// L'ora tipica delle sessioni vere di Marco, o null se non ne ha ancora.
  ///
  /// Si guardano le sessioni più recenti, comprese quelle ancora aperte: per
  /// sapere QUANDO ci si allena conta l'inizio, non se la sessione è stata
  /// chiusa bene.
  Future<int?> trainingHour(String profileId) async {
    final workouts = _database.workouts;
    final rows =
        await (_database.select(workouts)
              ..where(
                (row) =>
                    row.profileId.equals(profileId) & row.deletedAt.isNull(),
              )
              ..orderBy([(row) => OrderingTerm.desc(row.startedAt)])
              ..limit(trainingHourSample))
            .get();
    return typicalTrainingHour(rows.map((row) => row.startedAt));
  }

  /// Mette una scheda su un giorno della settimana (o la sostituisce).
  ///
  /// Il nome della scheda viene copiato nella riga: è lo snapshot che tiene in
  /// piedi il giorno quando la scheda verrà cancellata, ed è la ragione per
  /// cui il chiamante passa un id e non un nome — il nome lo sa il database,
  /// non la schermata.
  ///
  /// Una scheda già cancellata resta scrivibile: il giorno la mostra col suo
  /// nome e senza collegamento, che è esattamente lo stato in cui l'import di
  /// Gym ha lasciato cinque giorni. Un id che non esiste proprio è invece un
  /// errore di programmazione e viene rifiutato.
  Future<void> setDay({
    required String profileId,
    required int weekday,
    required String routineId,
  }) async {
    _requireWeekday(weekday);
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final routine = await (_database.select(
        _database.routines,
      )..where((row) => row.id.equals(routineId))).getSingleOrNull();
      if (routine == null) {
        throw ArgumentError.value(
          routineId,
          'routineId',
          'nessuna scheda con questo id',
        );
      }
      final live = routine.deletedAt == null;
      final id = dayId(profileId, weekday);
      // Una riga per quel giorno con un id DIVERSO può esistere: il pull la
      // scrive con l'id che arriva dal server, e un dispositivo vecchio
      // potrebbe averne generato uno suo. Va tolta prima, o la UNIQUE
      // (profilo, giorno) farebbe fallire l'upsert — che è esattamente ciò che
      // fa anche `_applyWeeklyPlanDay` quando riceve un cambiamento remoto.
      await (_database.delete(_database.routineWeeklyPlan)..where(
            (row) =>
                row.profileId.equals(profileId) &
                row.weekday.equals(weekday) &
                row.id.equals(id).not(),
          ))
          .go();
      await _database
          .into(_database.routineWeeklyPlan)
          .insertOnConflictUpdate(
            RoutineWeeklyPlanCompanion.insert(
              id: id,
              profileId: profileId,
              weekday: weekday,
              // Il CHECK del database pretende che la chiave esterna, quando
              // c'è, coincida con l'id esterno: sono lo stesso identificatore
              // visto da due lati.
              routineId: Value(live ? routine.id : null),
              routineExternalId: Value(routine.id),
              routineNameSnapshot: Value(routine.name),
              updatedAt: now,
            ),
          );
      await _appendWeekOutbox(profileId, now);
    });
  }

  /// Toglie la scheda dal giorno: torna riposo, cioè torna a non esistere.
  Future<void> clearDay({
    required String profileId,
    required int weekday,
  }) async {
    _requireWeekday(weekday);
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final removed =
          await (_database.delete(_database.routineWeeklyPlan)..where(
                (row) =>
                    row.profileId.equals(profileId) &
                    row.weekday.equals(weekday),
              ))
              .go();
      // Niente da togliere, niente da mandare: un giorno già di riposo non
      // deve generare una mutation che riscrive la settimana per nulla.
      if (removed == 0) {
        return;
      }
      await _appendWeekOutbox(profileId, now);
    });
  }

  /// Accoda la settimana INTERA, non il giorno che è appena cambiato.
  ///
  /// Il contratto remoto è una sostituzione in blocco: le righe che non sono
  /// nell'elenco vengono tombstonate. È l'unico modo di far viaggiare un
  /// giorno tolto, che qui è una riga sparita e non un tombstone.
  Future<void> _appendWeekOutbox(String profileId, DateTime now) async {
    final rows =
        await (_database.select(_database.routineWeeklyPlan)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.weekday)]))
            .get();
    await _database
        .into(_database.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            id: _uuid.v4(),
            entityType: syncEntityType,
            // L'entità è la settimana, e la settimana è del profilo: due
            // modifiche in fila diventano due mutation dello stesso oggetto,
            // che è ciò di cui l'ordine per entità si prende cura.
            entityId: profileId,
            operation: 'upsert',
            payloadJson: jsonEncode({
              'profile_id': profileId,
              'updated_at': now.toIso8601String(),
              // La chiave c'è SEMPRE, anche vuota: `[]` significa «settimana
              // tutta di riposo» e va tombstonata di là, mentre la chiave
              // assente significherebbe «questa scrittura non parla dei
              // giorni» e li lascerebbe stare.
              'days': [
                for (final row in rows)
                  {
                    'id': row.id,
                    'weekday': row.weekday,
                    'routine_id': row.routineId,
                    'routine_external_id': row.routineExternalId,
                    'routine_name_snapshot': row.routineNameSnapshot,
                  },
              ],
            }),
            createdAt: now,
          ),
        );
  }

  static void _requireWeekday(int weekday) {
    if (weekday < 1 || weekday > 7) {
      throw ArgumentError.value(
        weekday,
        'weekday',
        'giorno ISO fuori intervallo (1 = lunedì … 7 = domenica)',
      );
    }
  }

  /// La settimana con la scheda viva e i suoi esercizi principali.
  ///
  /// Gli esercizi entrano nel join (invece di essere contati a parte) perché
  /// così lo stream si aggiorna anche quando la scheda cambia: una riga in
  /// più nella query, un numero che non resta indietro.
  JoinedSelectStatement<HasResultSet, dynamic> _query(String profileId) {
    final plan = _database.routineWeeklyPlan;
    final routines = _database.routines;
    final exercises = _database.routineExercises;
    return _database.select(plan).join([
      leftOuterJoin(
        routines,
        routines.id.equalsExp(plan.routineId) & routines.deletedAt.isNull(),
      ),
      leftOuterJoin(
        exercises,
        exercises.routineId.equalsExp(routines.id) &
            exercises.block.equals(_mainBlock),
      ),
    ])..where(plan.profileId.equals(profileId));
  }

  List<PlannedWorkout> _workoutsFrom(List<TypedResult> rows) {
    final plan = _database.routineWeeklyPlan;
    final days = <int, LocalRoutineWeeklyPlanDay>{};
    final routines = <int, LocalRoutine?>{};
    final exerciseIds = <int, Set<String>>{};
    for (final row in rows) {
      final day = row.readTable(plan);
      days[day.weekday] = day;
      routines[day.weekday] = row.readTableOrNull(_database.routines);
      final exercise = row.readTableOrNull(_database.routineExercises);
      if (exercise != null) {
        exerciseIds.putIfAbsent(day.weekday, () => <String>{}).add(exercise.id);
      }
    }
    final workouts = [
      for (final day in days.values)
        PlannedWorkout(
          weekday: day.weekday,
          routineId: routines[day.weekday]?.id,
          routineName:
              routines[day.weekday]?.name ??
              day.routineNameSnapshot ??
              'Allenamento',
          isCircuit: routines[day.weekday]?.isCircuit ?? false,
          exerciseCount: exerciseIds[day.weekday]?.length ?? 0,
        ),
    ]..sort((first, second) => first.weekday.compareTo(second.weekday));
    return List.unmodifiable(workouts);
  }
}

final workoutPlanRepositoryProvider = Provider<WorkoutPlanRepository>(
  (ref) => WorkoutPlanRepository(ref.watch(databaseProvider)),
);

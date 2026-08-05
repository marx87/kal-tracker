import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_week.dart';
import 'package:kal_tracker/features/weekly_plan/domain/post_workout_meal.dart';

/// La metà «palestra» della settimana unificata: SOLA LETTURA.
///
/// `routine_weekly_plan` (giorno ISO 1-7 → scheda) è la settimana che Marco
/// ha deciso nelle schede, e resta di quel modulo: qui non si scrive niente.
/// Si legge per mostrarla accanto ai pasti e per dire al pianificatore quando
/// ci si allena.
///
/// Un giorno assente È l'informazione: significa riposo (in Firestore serviva
/// un `set()` senza merge, qui basta la riga mancante).
class WorkoutPlanRepository {
  const WorkoutPlanRepository(this._database);

  /// Quante sessioni si guardano per capire a che ora Marco si allena.
  /// Abbastanza da coprire un paio di mesi, poche da seguire un cambio di
  /// abitudini invece di restare ferme sul primo anno di storico.
  static const int trainingHourSample = 40;

  /// Solo il blocco principale conta come «esercizi» della scheda: il
  /// riscaldamento e il finisher si contano a parte nel modulo Palestra, e
  /// qui servirebbero solo a gonfiare un numero.
  static const String _mainBlock = 'main';

  final AppDatabase _database;

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

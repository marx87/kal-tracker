import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/coach/domain/coach_metrics.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';
import 'package:kal_tracker/features/coach/domain/coach_strength.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';

/// Legge — e basta — la fotografia su cui lavora il motore.
///
/// Non scrive niente e non calcola niente: le query stanno qui, l'aritmetica
/// sta in [CoachEngine]. Così il motore si prova senza database e il
/// repository si prova con un database vero.
class CoachSnapshotRepository {
  CoachSnapshotRepository(this._database);

  /// Quante settimane si caricano: la settimana del rapporto, quella di
  /// confronto e le due che servono al ritmo osservato della proiezione.
  static const int weeksLoaded = CoachEngine.maxRateWeeks + 1;

  /// Quanto indietro devono arrivare le serie: il salto di tre settimane più
  /// la finestra di allora.
  ///
  /// **Non si eredita da [weeksLoaded]**, che oggi ci arriva allo stesso
  /// giorno per aritmetica (35 giorni tondi tutte e due). È una coincidenza,
  /// e il giorno in cui una delle due costanti cambia il quinto segnale
  /// tornerebbe cieco senza che nessuno se ne accorga: qui la finestra si
  /// ricava da chi la usa.
  static const int strengthDaysLoaded =
      CoachStrength.comparisonGapDays + CoachStrength.windowDays;

  final AppDatabase _database;

  Future<CoachSnapshot> load({
    required String profileId,
    required CoachWeek week,
    CoachTargets? targets,
    CoachGoalContext? goal,
  }) async {
    // La finestra parte dall'inizio della settimana più vecchia che serve e
    // arriva a fine domenica: `end` è un'etichetta di giorno, quindi il
    // limite superiore è la mezzanotte del giorno dopo.
    final from = week.end.subtract(Duration(days: 7 * weeksLoaded - 1));
    final to = week.end.add(const Duration(days: 1));

    return CoachSnapshot(
      week: week,
      diary: await _diary(profileId: profileId, from: from, to: to),
      weighIns: await _weighIns(profileId: profileId, from: from, to: to),
      sessions: await _sessions(profileId: profileId, from: from, to: to),
      strengthSets: await _strengthSets(
        profileId: profileId,
        from: week.end.subtract(const Duration(days: strengthDaysLoaded - 1)),
        to: to,
      ),
      water: await _water(profileId: profileId, from: from, to: to),
      targets: targets,
      goal: goal,
    );
  }

  /// Quanti allenamenti prevede la settimana tipo (il piano giorno → scheda
  /// di Gym).
  ///
  /// Zero significa «non previsto», e allora l'aderenza sugli allenamenti
  /// sparisce dal rapporto invece di inventare un obbligo per poi misurarlo.
  /// I giorni configurati senza scheda sono giorni di riposo dichiarati e non
  /// contano.
  Future<int> plannedWorkoutsPerWeek(String profileId) async {
    final rows =
        await (_database.select(_database.routineWeeklyPlan)..where(
              (row) =>
                  row.profileId.equals(profileId) &
                  row.routineNameSnapshot.isNotNull(),
            ))
            .get();
    return rows.length;
  }

  /// Calorie e proteine per giorno civile romano. I giorni senza diario
  /// semplicemente non compaiono: chi legge deve poterli distinguere da un
  /// digiuno.
  Future<List<CoachDiaryDay>> _diary({
    required String profileId,
    required DateTime from,
    required DateTime to,
  }) async {
    final meals = _database.meals;
    final items = _database.mealItems;
    final query =
        _database.select(meals).join([
          innerJoin(items, items.mealId.equalsExp(meals.id)),
        ])..where(
          meals.profileId.equals(profileId) &
              meals.deletedAt.isNull() &
              items.deletedAt.isNull() &
              meals.eatenAt.isBiggerOrEqualValue(from) &
              meals.eatenAt.isSmallerThanValue(to),
        );

    final kcal = <DateTime, double>{};
    final protein = <DateTime, double>{};
    for (final row in await query.get()) {
      final day = bodyDayOf(row.readTable(meals).eatenAt);
      final item = row.readTable(items);
      kcal[day] = (kcal[day] ?? 0) + item.totalCalories;
      protein[day] = (protein[day] ?? 0) + item.totalProtein;
    }

    final days = kcal.keys.toList()..sort();
    return [
      for (final day in days)
        CoachDiaryDay(
          day: day,
          kcal: kcal[day]!,
          proteinGrams: protein[day] ?? 0,
        ),
    ];
  }

  Future<List<BodyMeasurement>> _weighIns({
    required String profileId,
    required DateTime from,
    required DateTime to,
  }) async {
    final query = _database.select(_database.bodyMeasurements)
      ..where(
        (row) =>
            row.profileId.equals(profileId) &
            row.deletedAt.isNull() &
            row.measuredAt.isBiggerOrEqualValue(from) &
            row.measuredAt.isSmallerThanValue(to),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.measuredAt)]);

    return [
      for (final row in await query.get())
        BodyMeasurement(
          id: row.id,
          measuredAt: row.measuredAt,
          weightKg: row.weightKg,
          hasImpedance: row.hasImpedance,
          // Senza impedenza le percentuali non sono misure: la bilancia le
          // lascia vuote e il coach non le inventa.
          bodyFatPct: row.bodyFatPct,
          musclePct: row.musclePct,
          waterPct: row.waterPct,
          impedanceOhm: row.impedanceOhm,
          source: row.source,
          note: row.note,
        ),
    ];
  }

  /// Le sessioni concluse. Una ancora aperta non è una settimana di
  /// allenamento, è un cronometro dimenticato acceso.
  Future<List<CoachSession>> _sessions({
    required String profileId,
    required DateTime from,
    required DateTime to,
  }) async {
    final query = _database.select(_database.workouts)
      ..where(
        (row) =>
            row.profileId.equals(profileId) &
            row.deletedAt.isNull() &
            row.endedAt.isNotNull() &
            row.startedAt.isBiggerOrEqualValue(from) &
            row.startedAt.isSmallerThanValue(to),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.startedAt)]);

    return [
      for (final row in await query.get())
        CoachSession(
          at: row.startedAt,
          rpe: row.rpe,
          satisfaction: row.satisfaction,
          mood: row.mood,
          durationMinutes: _minutesOf(row),
        ),
    ];
  }

  /// La durata attendibile, in minuti. Le sessioni con la pausa non
  /// registrata o rimaste aperte per giorni sono marcate `durationSuspect`
  /// dall'importer: quelle non producono un numero, producono un buco.
  static int? _minutesOf(LocalWorkout row) {
    if (row.durationSuspect) {
      return null;
    }
    final seconds =
        row.finalDurationSeconds ??
        (row.endedAt == null
            ? null
            : row.endedAt!.difference(row.startedAt).inSeconds -
                  row.accumulatedPauseSeconds);
    if (seconds == null || seconds <= 0) {
      return null;
    }
    return seconds ~/ 60;
  }

  /// Le serie da cui si misura la forza, già scremate qui e non nel dominio.
  ///
  /// La scrematura sta in SQL per la stessa ragione per cui ci sta quella
  /// delle sessioni concluse: il coach riceve una fotografia pronta e
  /// `CoachStrengthSet` non conosce `Workout`. Restano fuori i riscaldamenti,
  /// le serie mai spuntate — un carico scritto e non eseguito non è forza — e
  /// tutto ciò che non ha insieme carico e ripetizioni, cioè il cardio e i
  /// blocchi a tempo, dove un massimale non vuol dire niente.
  Future<List<CoachStrengthSet>> _strengthSets({
    required String profileId,
    required DateTime from,
    required DateTime to,
  }) async {
    final workouts = _database.workouts;
    final exercises = _database.workoutExercises;
    final sets = _database.workoutSets;

    final query =
        _database.select(sets).join([
            innerJoin(
              exercises,
              exercises.id.equalsExp(sets.workoutExerciseId),
            ),
            innerJoin(workouts, workouts.id.equalsExp(exercises.workoutId)),
          ])
          ..where(
            workouts.profileId.equals(profileId) &
                workouts.deletedAt.isNull() &
                workouts.endedAt.isNotNull() &
                workouts.startedAt.isBiggerOrEqualValue(from) &
                workouts.startedAt.isSmallerThanValue(to) &
                sets.completed.equals(true) &
                sets.isWarmup.equals(false) &
                // **Anche l'esercizio**, non solo la serie. Nell'export di
                // Gym ci sono 68 righe esercizio marcate riscaldamento le cui
                // serie non portano il flag: senza questo filtro un
                // riscaldamento pesante entra nell'e1RM e può far sembrare la
                // forza in calo quando non lo è — e la forza è il segnale che
                // accende il semaforo del sovrallenamento, la cui risposta è
                // «alleggerisci» o «mangia di più». Un allarme costruito su un
                // riscaldamento è peggio di nessun allarme.
                exercises.isWarmup.equals(false) &
                sets.weightKg.isBiggerThanValue(0) &
                sets.reps.isBiggerThanValue(0),
          )
          ..orderBy([OrderingTerm.asc(workouts.startedAt)]);

    return [
      for (final row in await query.get())
        CoachStrengthSet(
          at: row.readTable(workouts).startedAt,
          // L'id ORIGINALE, non la chiave viva verso il catalogo: quella
          // diventa nulla quando l'esercizio viene cancellato, ed esercizi
          // diversi collasserebbero in una voce sola. È la stessa chiave con
          // cui raggruppano i record personali.
          exerciseId: row.readTable(exercises).exerciseRefId,
          exerciseName: row.readTable(exercises).exerciseNameSnapshot,
          // Il `!` è quello che il WHERE ha appena garantito: un NULL non
          // sopravvive a un confronto con zero.
          weightKg: row.readTable(sets).weightKg!,
          reps: row.readTable(sets).reps!,
        ),
    ];
  }

  Future<List<CoachWaterDay>> _water({
    required String profileId,
    required DateTime from,
    required DateTime to,
  }) async {
    final query = _database.select(_database.waterLogs)
      ..where(
        (row) =>
            row.profileId.equals(profileId) &
            row.deletedAt.isNull() &
            row.loggedAt.isBiggerOrEqualValue(from) &
            row.loggedAt.isSmallerThanValue(to),
      );

    final totals = <DateTime, int>{};
    for (final row in await query.get()) {
      final day = bodyDayOf(row.loggedAt);
      totals[day] = (totals[day] ?? 0) + row.milliliters;
    }
    final days = totals.keys.toList()..sort();
    return [
      for (final day in days)
        CoachWaterDay(day: day, milliliters: totals[day]!),
    ];
  }
}

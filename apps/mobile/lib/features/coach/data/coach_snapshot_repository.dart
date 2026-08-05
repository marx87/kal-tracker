import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/coach/domain/coach_metrics.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';
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

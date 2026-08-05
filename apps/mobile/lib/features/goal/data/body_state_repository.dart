import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';

/// Legge — e basta — lo stato del corpo dalle tabelle che ci sono già:
/// pesate da `body_measurements`, calorie da `meals` + `meal_items`.
///
/// Non scrive nulla: l'Obiettivo non è il padrone di questi dati, li usa.
class BodyStateRepository {
  BodyStateRepository(this._database);

  final AppDatabase _database;

  /// Quanto indietro si guarda per trovare l'ultima composizione corporea.
  /// Oltre sei mesi una percentuale di grasso non descrive più questo corpo.
  static const int compositionHorizonDays = 180;

  /// La finestra su cui si misura il consumo reale.
  static const int tdeeWindowDays = 28;

  /// Si aggiorna a ogni pesata.
  ///
  /// Nota: una voce aggiunta al diario **non** fa ripartire questo stream —
  /// le calorie vengono rilette alla pesata successiva o quando la schermata
  /// viene ricaricata. È una scelta: il TDEE misurato si muove su settimane,
  /// non su un panino.
  Stream<BodyState> watch(String profileId) async* {
    final query = _database.select(_database.bodyMeasurements)
      ..where(
        (row) =>
            row.profileId.equals(profileId) &
            row.deletedAt.isNull() &
            row.measuredAt.isBiggerOrEqualValue(
              AppTime.nowUtc().subtract(
                const Duration(days: compositionHorizonDays),
              ),
            ),
      )
      ..orderBy([(row) => OrderingTerm.desc(row.measuredAt)]);

    await for (final rows in query.watch()) {
      yield await _build(profileId: profileId, rows: rows);
    }
  }

  Future<BodyState> load(String profileId) async {
    final query = _database.select(_database.bodyMeasurements)
      ..where(
        (row) =>
            row.profileId.equals(profileId) &
            row.deletedAt.isNull() &
            row.measuredAt.isBiggerOrEqualValue(
              AppTime.nowUtc().subtract(
                const Duration(days: compositionHorizonDays),
              ),
            ),
      )
      ..orderBy([(row) => OrderingTerm.desc(row.measuredAt)]);
    return _build(profileId: profileId, rows: await query.get());
  }

  Future<BodyState> _build({
    required String profileId,
    required List<LocalBodyMeasurement> rows,
  }) async {
    if (rows.isEmpty) {
      return const BodyState.unknown();
    }

    final points = [
      for (final row in rows)
        WeightPoint(
          at: row.measuredAt,
          weightKg: row.weightKg,
          // Senza impedenza le percentuali non sono misure: la bilancia le
          // lascia vuote e noi non le inventiamo.
          bodyFatPct: row.bodyFatPct,
        ),
    ];

    final now = AppTime.nowUtc();
    final withComposition = BodyStateMath.latestWithComposition(points);
    final windowStart = now.subtract(const Duration(days: tdeeWindowDays));
    final windowPoints = points
        .where((point) => !point.at.toUtc().isBefore(windowStart))
        .toList(growable: false);

    return BodyState(
      latest: points.first,
      fatFreeMassKg: BodyStateMath.fatFreeMassOf(withComposition),
      fatFreeMassMeasuredAt: withComposition?.at,
      sevenDayAverageKg: BodyStateMath.averageWithinDays(
        points: points,
        now: now,
      ),
      tdeeSample: BodyStateMath.buildSample(
        points: windowPoints,
        dailyKcal: await _dailyCalories(
          profileId: profileId,
          from: windowStart,
        ),
        dayKeyOf: AppTime.romeDateString,
      ),
    );
  }

  /// Calorie per giorno civile romano. I giorni senza diario semplicemente
  /// non compaiono: chi legge deve poterli distinguere da un digiuno.
  Future<Map<String, double>> _dailyCalories({
    required String profileId,
    required DateTime from,
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
              meals.eatenAt.isBiggerOrEqualValue(from),
        );

    final totals = <String, double>{};
    for (final row in await query.get()) {
      final key = AppTime.romeDateString(row.readTable(meals).eatenAt);
      totals[key] = (totals[key] ?? 0) + row.readTable(items).totalCalories;
    }
    return totals;
  }
}

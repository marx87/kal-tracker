import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/body/domain/body_analysis.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';

/// Una giornata di diario, già sommata.
///
/// I giorni senza diario **non compaiono**: valgono «non so», non «zero
/// calorie». Un digiuno e una giornata non registrata sono due cose diverse e
/// mediarle insieme abbasserebbe il consumo misurato di centinaia di kcal.
@immutable
class CoachDiaryDay {
  const CoachDiaryDay({
    required this.day,
    required this.kcal,
    required this.proteinGrams,
  });

  /// Etichetta di giorno civile romano ([bodyDayOf]).
  final DateTime day;

  final double kcal;
  final double proteinGrams;
}

/// Una sessione di allenamento, per quel poco che il coach le chiede.
///
/// Quasi tutti i campi sono nullable **per forza**: nello storico reale di
/// Marco RPE e soddisfazione sono compilati in 17 sessioni su 29 e l'umore in
/// 11. Il coach deve funzionare con questi buchi, non nonostante.
@immutable
class CoachSession {
  const CoachSession({
    required this.at,
    this.rpe,
    this.satisfaction,
    this.mood,
    this.durationMinutes,
  });

  final DateTime at;

  /// Sforzo percepito 1-10.
  final int? rpe;

  final int? satisfaction;
  final int? mood;
  final int? durationMinutes;
}

/// L'acqua bevuta in un giorno.
@immutable
class CoachWaterDay {
  const CoachWaterDay({required this.day, required this.milliliters});

  final DateTime day;
  final int milliliters;
}

/// Quello che era previsto: serve solo all'aderenza.
///
/// Nullo quando non c'è un obiettivo impostato: senza previsione non c'è
/// scostamento da misurare, e il rapporto parla lo stesso di tutto il resto.
@immutable
class CoachTargets {
  const CoachTargets({
    required this.dailyCalories,
    required this.dailyProtein,
    this.weeklyWorkouts = 0,
  });

  final double dailyCalories;
  final double dailyProtein;

  /// Allenamenti previsti nella settimana. Zero significa «non previsto»:
  /// l'aderenza sugli allenamenti sparisce invece di dare sempre 100%.
  final int weeklyWorkouts;
}

/// Il traguardo, per la sola proiezione. Il coach non lo cambia mai.
@immutable
class CoachGoalContext {
  const CoachGoalContext({
    required this.targetWeightKg,
    required this.paceKgPerWeek,
    this.plannedDate,
    this.phaseLabel,
  });

  final double targetWeightKg;
  final double paceKgPerWeek;

  /// La data che l'obiettivo prometteva. Nulla in mantenimento: non c'è un
  /// arrivo da mancare.
  final DateTime? plannedDate;

  final String? phaseLabel;
}

/// **Tutto ciò che il motore legge.** Una fotografia, non una connessione:
/// il repository la costruisce dal database e da lì in poi ogni calcolo è
/// una funzione pura di questo oggetto.
@immutable
class CoachSnapshot {
  const CoachSnapshot({
    required this.week,
    this.diary = const [],
    this.weighIns = const [],
    this.sessions = const [],
    this.water = const [],
    this.targets,
    this.goal,
    this.activity = ActivityLevel.moderate,
  });

  final CoachWeek week;

  /// Diario delle due settimane (quella del rapporto e quella prima).
  final List<CoachDiaryDay> diary;

  /// Pesate grezze. Si riusa il tipo della schermata Corpo apposta: il
  /// vocabolario della composizione corporea deve restare uno solo.
  final List<BodyMeasurement> weighIns;

  final List<CoachSession> sessions;
  final List<CoachWaterDay> water;

  final CoachTargets? targets;
  final CoachGoalContext? goal;

  /// Serve solo alla stima da metabolismo basale delle prime settimane.
  final ActivityLevel activity;

  List<CoachDiaryDay> diaryIn(CoachWeek window) => [
    for (final day in diary)
      if (window.containsDay(day.day)) day,
  ];

  List<CoachSession> sessionsIn(CoachWeek window) => [
    for (final session in sessions)
      if (window.contains(session.at)) session,
  ];

  List<CoachWaterDay> waterIn(CoachWeek window) => [
    for (final day in water)
      if (window.containsDay(day.day)) day,
  ];

  CoachAverages averagesIn(CoachWeek window) =>
      CoachAverages.of(weighIns, window);

  /// La massa magra più recente misurata davvero, in tutta la fotografia.
  ///
  /// Cambia lentamente: vale anche se la pesata di stamattina non aveva
  /// l'impedenza.
  double? get latestFatFreeMassKg {
    BodyMeasurement? best;
    for (final measurement in weighIns) {
      if (!measurement.hasComposition) {
        continue;
      }
      if (best == null || measurement.measuredAt.isAfter(best.measuredAt)) {
        best = measurement;
      }
    }
    return best?.leanMassKg;
  }
}

/// Le medie a 7 giorni di una settimana: **un numero per finestra**, non una
/// serie.
///
/// Non è la media mobile di `BodyAnalysis` — quella produce un punto per ogni
/// giorno con pesata, e serve al grafico. Qui serve il singolo valore con cui
/// confrontare due settimane, e il filtro contro il rumore è lo stesso:
/// prima si collassano le letture dello stesso giorno ([BodyAnalysis.collapseDays]),
/// poi si media sui giorni. Un giorno con quattro salite sulla bilancia pesa
/// come un giorno con una sola.
@immutable
class CoachAverages {
  const CoachAverages({
    required this.week,
    required this.dayCount,
    this.weightKg,
    this.fatMassKg,
    this.leanMassKg,
    this.bodyWaterPct,
    this.compositionDays = 0,
  });

  factory CoachAverages.of(
    List<BodyMeasurement> measurements,
    CoachWeek window,
  ) {
    final inside = [
      for (final measurement in measurements)
        if (window.contains(measurement.measuredAt)) measurement,
    ];
    if (inside.isEmpty) {
      return CoachAverages(week: window, dayCount: 0);
    }

    final days = BodyAnalysis.collapseDays(inside);
    final withComposition = [
      for (final day in days)
        if (day.hasComposition) day,
    ];

    // L'acqua corporea non sta in `BodyDayPoint`: si media qui, per giorno,
    // con lo stesso criterio delle masse.
    final waterByDay = <DateTime, List<double>>{};
    for (final measurement in inside) {
      final water = measurement.waterPct;
      if (water == null || water <= 0) {
        continue;
      }
      waterByDay.putIfAbsent(measurement.day, () => []).add(water);
    }
    final waterDayMeans = [
      for (final readings in waterByDay.values) _mean(readings)!,
    ];

    return CoachAverages(
      week: window,
      dayCount: days.length,
      weightKg: _mean(days.map((day) => day.weightKg)),
      fatMassKg: _mean(withComposition.map((day) => day.fatMassKg!)),
      leanMassKg: _mean(withComposition.map((day) => day.leanMassKg!)),
      bodyWaterPct: _mean(waterDayMeans),
      compositionDays: withComposition.length,
    );
  }

  final CoachWeek week;

  /// Giorni distinti con almeno una pesata. Sotto i 3 la «media a 7 giorni»
  /// è ancora quasi un dato grezzo, e il rapporto lo dichiara.
  final int dayCount;

  final double? weightKg;
  final double? fatMassKg;
  final double? leanMassKg;
  final double? bodyWaterPct;
  final int compositionDays;

  bool get hasWeight => weightKg != null;
  bool get hasComposition => leanMassKg != null && fatMassKg != null;

  /// Una media fatta di un giorno solo non è una media: si può mostrare, ma
  /// non ci si costruisce sopra un semaforo.
  bool get isSolid => dayCount >= 3;
}

double? _mean(Iterable<double> values) {
  var total = 0.0;
  var count = 0;
  for (final value in values) {
    total += value;
    count++;
  }
  return count == 0 ? null : total / count;
}

/// Media delle calorie e delle proteine dei giorni **registrati**.
@immutable
class CoachIntake {
  const CoachIntake({
    required this.days,
    this.averageKcal,
    this.averageProteinGrams,
  });

  factory CoachIntake.of(List<CoachDiaryDay> days) => CoachIntake(
    days: days.length,
    averageKcal: _mean(days.map((day) => day.kcal)),
    averageProteinGrams: _mean(days.map((day) => day.proteinGrams)),
  );

  /// Giorni con diario, non giorni della settimana.
  final int days;

  final double? averageKcal;
  final double? averageProteinGrams;

  bool get hasData => averageKcal != null;
}

import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/coach/domain/coach_adherence.dart';
import 'package:kal_tracker/features/coach/domain/coach_false_movement.dart';
import 'package:kal_tracker/features/coach/domain/coach_overtraining.dart';
import 'package:kal_tracker/features/coach/domain/coach_projection.dart';
import 'package:kal_tracker/features/coach/domain/coach_recomposition.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';
import 'package:kal_tracker/features/coach/domain/coach_strength.dart';
import 'package:kal_tracker/features/coach/domain/coach_tdee.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';

/// **Il rapporto della domenica, per la parte che è aritmetica.**
///
/// Qui dentro non c'è una sola parola scritta da un modello: TDEE, aderenza,
/// ricomposizione, proiezione, semaforo e movimenti falsi sono funzioni pure
/// dei dati di Marco. Il modello riceve questo oggetto già fatto e scrive
/// soltanto il perché.
///
/// Corollario pratico: **il rapporto esiste anche con il Mac spento.** Quello
/// che manca senza il Mac è il commento, non i numeri.
@immutable
class CoachMetrics {
  const CoachMetrics({
    required this.week,
    required this.tdee,
    required this.adherence,
    required this.recomposition,
    required this.overtraining,
    required this.falseMovement,
    required this.intake,
    required this.averages,
    required this.previousAverages,
    required this.workoutsDone,
    this.projection,
    this.observedKgPerWeek,
    this.rateWeeks = 0,
  });

  final CoachWeek week;
  final WeeklyTdee tdee;
  final WeeklyAdherence adherence;
  final Recomposition recomposition;
  final OvertrainingLight overtraining;
  final FalseMovement falseMovement;

  final CoachIntake intake;
  final CoachAverages averages;
  final CoachAverages previousAverages;
  final int workoutsDone;

  /// Nulla senza obiettivo: l'app deve funzionare anche senza traguardo, e
  /// un rapporto senza proiezione è comunque un rapporto.
  final GoalProjection? projection;

  /// Il ritmo osservato usato dalla proiezione, in kg a settimana.
  final double? observedKgPerWeek;

  /// Su quante settimane è stato misurato.
  final int rateWeeks;

  /// Le frasi deterministiche, nell'ordine in cui si leggono. Sono anche
  /// quelle che viaggiano verso il modello: lui le rilegge e scrive il
  /// perché, non le riscrive.
  List<String> get headlines => [
    if (tdee.isMeasured)
      'Consumo misurato questa settimana: ${tdee.kcal.round()} kcal.'
    else
      'Consumo ancora stimato: ${tdee.kcal.round()} kcal.',
    'Aderenza: ${adherence.overall.label.toLowerCase()}.',
    recomposition.headline,
    ?projection?.headline,
    overtraining.headline,
    ?falseMovement.explanation,
  ];

  /// Quanto è affidabile il rapporto: quante caselle sono piene.
  ///
  /// Non è un voto sulla settimana, è un voto sui **dati**: serve a non far
  /// sembrare solida una lettura fatta su due pesate.
  int get filledSlots {
    var filled = 0;
    if (intake.days >= CoachAdherence.minimumDiaryDays) {
      filled++;
    }
    if (averages.isSolid) {
      filled++;
    }
    if (recomposition.isKnown) {
      filled++;
    }
    if (overtraining.knownCount >= 2) {
      filled++;
    }
    return filled;
  }

  static const int totalSlots = 4;

  /// La richiesta che va sul Mac: **solo numeri già calcolati e frasi già
  /// scritte**. Il modello non riceve dati grezzi da cui ricavarne altri.
  Map<String, Object?> toRequestJson() => {
    'week_start': _dayString(week.start),
    'week_end': _dayString(week.end),
    'tdee': {
      'kcal': tdee.kcal.round(),
      'source': tdee.isMeasured ? 'misurato' : 'stimato',
      'average_daily_kcal': tdee.averageDailyKcal?.round(),
      'weight_change_kg': _rounded(tdee.weightChangeKg, 2),
      'diary_days': tdee.diaryDays,
      'weigh_in_days': tdee.weighInDays,
    },
    'adherence': {
      'overall': adherence.overall.name,
      'lines': [
        for (final line in adherence.lines)
          {
            'label': line.label,
            'grade': line.grade.name,
            'planned': _rounded(line.planned, 1),
            'actual': _rounded(line.actual, 1),
            'unit': line.unit,
            'days_counted': line.daysCounted,
            'days_missing': line.daysMissing,
          },
      ],
    },
    'recomposition': {
      'lean_trend': recomposition.leanTrend.name,
      'lean_change_kg': _rounded(recomposition.leanChangeKg, 2),
      'fat_change_kg': _rounded(recomposition.fatChangeKg, 2),
      'is_recomposition': recomposition.isRecomposition,
    },
    'projection': projection == null
        ? null
        : {
            'state': projection!.state.name,
            'target_weight_kg': _rounded(projection!.targetWeightKg, 1),
            'current_average_kg': _rounded(projection!.currentAverageKg, 2),
            'observed_kg_per_week': _rounded(projection!.observedKgPerWeek, 3),
            'projected_date': _dayString(projection!.projectedDate),
            'planned_date': _dayString(projection!.plannedDate),
            'weeks_late': projection!.weeksLate,
          },
    'overtraining': {
      'level': overtraining.level.name,
      'fired': [for (final signal in overtraining.fired) signal.name],
      'unknown': [for (final signal in overtraining.unknown) signal.name],
      // La misura dietro il quinto segnale, non solo il suo colore: il
      // modello deve poter scrivere «sulla panca sollevi il 6 % in meno»
      // senza rifare il conto, e sugli esercizi che lo dicono davvero.
      'strength': {
        'change': _rounded(overtraining.strength.change, 4),
        'exercises': overtraining.strength.exercises,
      },
    },
    'false_movement': {
      'kind': falseMovement.kind.name,
      'daily_change_kg': _rounded(falseMovement.dailyChangeKg, 2),
      'trend_change_kg': _rounded(falseMovement.trendChangeKg, 2),
    },
    'workouts_done': workoutsDone,
    'data_quality': {'filled': filledSlots, 'total': totalSlots},
    // Le frasi già scritte dal motore: il modello le legge per non
    // contraddirle e per non ripeterle.
    'headlines': headlines,
  };

  static String? _dayString(DateTime? day) => day == null
      ? null
      : '${day.year.toString().padLeft(4, '0')}-'
            '${day.month.toString().padLeft(2, '0')}-'
            '${day.day.toString().padLeft(2, '0')}';

  static double? _rounded(double? value, int decimals) =>
      (value == null || !value.isFinite)
      ? null
      : double.parse(value.toStringAsFixed(decimals));
}

/// Il motore. Una funzione, un risultato: stessi dati, stesso rapporto.
abstract final class CoachEngine {
  /// Su quante settimane si cerca il ritmo per la proiezione. Quattro: una
  /// sola settimana di differenza è quasi tutta rumore, e otto smetterebbero
  /// di descrivere cosa si sta facendo adesso.
  static const int maxRateWeeks = 4;

  /// Giorni con pesata che una settimana deve avere per fare da estremo del
  /// ritmo osservato.
  static const int minimumRateDays = 2;

  static CoachMetrics run(CoachSnapshot snapshot, {DateTime? today}) {
    final week = snapshot.week;
    final previousWeek = week.previous;

    final currentAverages = snapshot.averagesIn(week);
    final previousAverages = snapshot.averagesIn(previousWeek);
    final intake = CoachIntake.of(snapshot.diaryIn(week));
    final sessions = snapshot.sessionsIn(week);
    final previousSessions = snapshot.sessionsIn(previousWeek);

    final tdee = CoachTdee.measure(
      fatFreeMassKg: snapshot.latestFatFreeMassKg,
      activity: snapshot.activity,
      averageDailyKcal: intake.averageKcal,
      currentWeekAverageKg: currentAverages.weightKg,
      previousWeekAverageKg: previousAverages.weightKg,
      diaryDays: intake.days,
      weighInDays: currentAverages.dayCount,
    );

    final adherence = CoachAdherence.assess(
      intake: intake,
      workoutsDone: sessions.length,
      targets: snapshot.targets,
    );

    final recomposition = CoachRecomposition.assess(
      current: currentAverages,
      previous: previousAverages,
    );

    final overtraining = CoachOvertraining.assess(
      currentSessions: sessions,
      previousSessions: previousSessions,
      currentAverages: currentAverages,
      previousAverages: previousAverages,
      proteinLine: adherence.protein,
      strength: CoachStrength.measure(
        sets: snapshot.strengthSets,
        // La domenica del rapporto, non `today`: le due finestre dell'e1RM
        // sono ancorate alla settimana di cui si parla, e rileggendo il
        // rapporto il mercoledì il quinto segnale non deve cambiare colore
        // da solo. È lo stesso motivo per cui la proiezione qui sotto parte
        // da `week.end`.
        referenceDay: week.end,
      ),
    );

    final falseMovement = CoachFalseMovement.detect(
      weighIns: [
        for (final measurement in snapshot.weighIns)
          if (week.contains(measurement.measuredAt)) measurement,
      ],
      current: currentAverages,
      previous: previousAverages,
      water: snapshot.water,
    );

    final (rate, rateWeeks) = _observedRate(snapshot, currentAverages);
    final goal = snapshot.goal;

    return CoachMetrics(
      week: week,
      tdee: tdee,
      adherence: adherence,
      recomposition: recomposition,
      overtraining: overtraining,
      falseMovement: falseMovement,
      intake: intake,
      averages: currentAverages,
      previousAverages: previousAverages,
      workoutsDone: sessions.length,
      observedKgPerWeek: rate,
      rateWeeks: rateWeeks,
      projection: goal == null
          ? null
          : CoachProjection.project(
              targetWeightKg: goal.targetWeightKg,
              currentAverageKg: currentAverages.weightKg,
              observedKgPerWeek: rate,
              weeksObserved: rateWeeks,
              // La proiezione parte dalla fine della settimana del rapporto,
              // non da «adesso»: rileggendolo il mercoledì la data non deve
              // spostarsi da sola.
              today: today ?? week.end,
              plannedKgPerWeek: goal.paceKgPerWeek,
              plannedDate: goal.plannedDate,
            ),
    );
  }

  /// Il ritmo osservato: la media a 7 giorni di adesso contro la più vecchia
  /// utilizzabile, entro [maxRateWeeks].
  static (double?, int) _observedRate(
    CoachSnapshot snapshot,
    CoachAverages current,
  ) {
    if (current.weightKg == null) {
      return (null, 0);
    }
    var window = snapshot.week;
    double? oldest;
    var weeks = 0;
    for (var back = 1; back <= maxRateWeeks; back++) {
      window = window.previous;
      final averages = snapshot.averagesIn(window);
      if (averages.weightKg == null || averages.dayCount < minimumRateDays) {
        continue;
      }
      oldest = averages.weightKg;
      weeks = back;
    }
    if (oldest == null || weeks == 0) {
      return (null, 0);
    }
    return (
      CoachProjection.rateKgPerWeek(
        currentAverageKg: current.weightKg,
        olderAverageKg: oldest,
        weeks: weeks,
      ),
      weeks,
    );
  }
}

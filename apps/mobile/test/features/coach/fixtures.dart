/// Attrezzi per i test del coach: una settimana finta ma plausibile.
///
/// I numeri di riferimento sono quelli veri di Marco (`../goal/marco.dart`):
/// 95,5 kg e 71,66 kg di massa magra. Non è vezzo: su quei valori esiste un
/// riscontro esterno — il BMR dichiarato dalla bilancia Renpho — e non solo
/// il nostro codice che conferma sé stesso.
library;

import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';
import 'package:kal_tracker/features/coach/domain/coach_strength.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';

/// La domenica di riferimento: 2 agosto 2026.
final CoachWeek testWeek = CoachWeek(end: DateTime.utc(2026, 8, 2));

/// Una settimana che finisce in un giorno qualunque: serve dove conta solo
/// contenere le pesate, non che sia una domenica.
CoachWeek testWeekEndingOn(DateTime day) => CoachWeek(end: day);

/// Una pesata alle 7 del mattino del giorno indicato.
BodyMeasurement weighIn(
  DateTime day, {
  required double weightKg,
  double? bodyFatPct,
  double? waterPct,
  String id = '',
}) => BodyMeasurement(
  id: id.isEmpty ? 'w-${day.toIso8601String()}-$weightKg' : id,
  // Le 5 UTC sono le 7 di Roma d'estate: dentro il giorno giusto senza
  // dipendere dal fuso della macchina che esegue i test.
  measuredAt: DateTime.utc(day.year, day.month, day.day, 5),
  weightKg: weightKg,
  hasImpedance: bodyFatPct != null,
  bodyFatPct: bodyFatPct,
  waterPct: waterPct,
  source: 'renpho_ble',
);

/// Una serie di pesate a giorni consecutivi, dall'ultimo all'indietro.
List<BodyMeasurement> weighInSeries({
  required DateTime lastDay,
  required List<double> weights,
  List<double?>? bodyFatPcts,
  List<double?>? waterPcts,
}) => [
  for (final (index, weight) in weights.indexed)
    weighIn(
      lastDay.subtract(Duration(days: weights.length - 1 - index)),
      weightKg: weight,
      bodyFatPct: bodyFatPcts == null ? null : bodyFatPcts[index],
      waterPct: waterPcts == null ? null : waterPcts[index],
    ),
];

/// Sette giorni di diario tutti uguali, che finiscono in [lastDay].
List<CoachDiaryDay> diaryWeek({
  required DateTime lastDay,
  required double kcal,
  required double proteinGrams,
  int days = 7,
}) => [
  for (var back = days - 1; back >= 0; back--)
    CoachDiaryDay(
      day: lastDay.subtract(Duration(days: back)),
      kcal: kcal,
      proteinGrams: proteinGrams,
    ),
];

/// Check-in a ritroso da [lastDay]: l'indice 0 è [lastDay], il 7 è lo stesso
/// giorno della settimana prima — cioè il termine di paragone del NEAT.
///
/// Un `null` è un giorno **non segnato**, che non è uno zero: la media si fa
/// sui giorni con il dato, e distinguere le due cose è tutto il senso del
/// campo. Le due misure convivono nello stesso giorno perché il rapporto ne
/// sceglie una sola, e la scelta si prova solo dandogliele entrambe.
CheckInLog checkInLog({
  required DateTime lastDay,
  List<int?> steps = const [],
  List<int?> walkMinutes = const [],
}) {
  final entries = <String, DailyCheckIn>{};
  final days = steps.length > walkMinutes.length
      ? steps.length
      : walkMinutes.length;
  for (var back = 0; back < days; back++) {
    final stepsOfDay = back < steps.length ? steps[back] : null;
    final walkOfDay = back < walkMinutes.length ? walkMinutes[back] : null;
    if (stepsOfDay == null && walkOfDay == null) {
      continue;
    }
    final day = lastDay.subtract(Duration(days: back));
    final entry = DailyCheckIn(
      day: day,
      updatedAt: day,
      steps: stepsOfDay,
      walkMinutes: walkOfDay,
    );
    entries[entry.dayKey] = entry;
  }
  return CheckInLog(Map.unmodifiable(entries));
}

/// Una sessione di allenamento alle 18 di Roma.
CoachSession session(DateTime day, {int? rpe, int? mood, int? satisfaction}) =>
    CoachSession(
      at: DateTime.utc(day.year, day.month, day.day, 16),
      rpe: rpe,
      mood: mood,
      satisfaction: satisfaction,
    );

/// Tre fondamentali, due giornate per lettura, le due letture a tre settimane
/// di distanza: il minimo che il confronto dell'e1RM accetta, riferito alla
/// domenica di [testWeek].
///
/// Le ripetizioni restano fisse, così l'e1RM è proporzionale al carico e la
/// variazione attesa si legge direttamente dai chili: qui non si prova la
/// formula di Epley, si prova che il segnale arriva a destinazione.
List<CoachStrengthSet> liftedWeeks({
  required double before,
  required double now,
}) => [
  for (final exercise in ['panca', 'squat', 'stacco'])
    for (final (day, weightKg) in [
      (DateTime.utc(2026, 7, 1), before),
      (DateTime.utc(2026, 7, 8), before),
      (DateTime.utc(2026, 7, 22), now),
      (DateTime.utc(2026, 7, 29), now),
    ])
      CoachStrengthSet(
        at: DateTime.utc(day.year, day.month, day.day, 16),
        exerciseId: exercise,
        exerciseName: exercise,
        weightKg: weightKg,
        reps: 5,
      ),
];

import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';

/// Quanto il reale si è discostato dal previsto.
///
/// Tre gradi e non un voto in decimi: «quasi» e «no» sono le sole due
/// distinzioni che cambiano cosa si fa dopo.
enum AdherenceGrade {
  /// Dentro la tolleranza: non c'è niente da correggere.
  onTrack(label: 'In linea'),

  /// Si scosta ma non abbastanza da cambiare il piano.
  drifting(label: 'Si scosta'),

  /// Lontano: è questo che il coach spiega.
  off(label: 'Lontano'),

  /// Non abbastanza dati per dirlo. **Non è un fallimento**: è il caso più
  /// frequente nella settimana in cui ci si dimentica di registrare.
  unknown(label: 'Dati insufficienti');

  const AdherenceGrade({required this.label});

  final String label;
}

/// Una riga di aderenza: calorie, proteine o allenamenti.
@immutable
class AdherenceLine {
  const AdherenceLine({
    required this.label,
    required this.grade,
    this.planned,
    this.actual,
    this.daysCounted = 0,
    this.daysExpected = 0,
    this.unit = '',
  });

  const AdherenceLine.unknown({
    required this.label,
    this.daysCounted = 0,
    this.daysExpected = 0,
    this.unit = '',
  }) : grade = AdherenceGrade.unknown,
       planned = null,
       actual = null;

  final String label;
  final AdherenceGrade grade;

  /// Il previsto. Nullo quando non c'è un obiettivo: senza previsione non
  /// esiste scostamento.
  final double? planned;

  /// Il reale.
  final double? actual;

  /// Giorni (o sessioni) che hanno contribuito.
  final int daysCounted;

  /// Giorni attesi: 7 per calorie e proteine, il numero di allenamenti
  /// previsti per la palestra.
  final int daysExpected;

  final String unit;

  bool get isKnown => grade != AdherenceGrade.unknown;

  /// Reale meno previsto. Negativo quando si è stati sotto.
  double? get deltaFromPlan =>
      (planned == null || actual == null) ? null : actual! - planned!;

  /// Reale / previsto. 1 è centrato.
  double? get ratio => (planned == null || planned == 0 || actual == null)
      ? null
      : actual! / planned!;

  /// Quanti giorni non hanno lasciato traccia.
  int get daysMissing {
    final missing = daysExpected - daysCounted;
    return missing > 0 ? missing : 0;
  }
}

/// L'aderenza della settimana su calorie, proteine e allenamenti.
@immutable
class WeeklyAdherence {
  const WeeklyAdherence({
    required this.calories,
    required this.protein,
    required this.workouts,
  });

  final AdherenceLine calories;
  final AdherenceLine protein;

  /// Nulla quando nessun allenamento era previsto: l'app non inventa un
  /// obbligo per poi misurarlo.
  final AdherenceLine? workouts;

  List<AdherenceLine> get lines => [calories, protein, ?workouts];

  /// Il grado peggiore fra quelli noti. Se non si sa niente, `unknown`.
  AdherenceGrade get overall {
    var worst = AdherenceGrade.unknown;
    for (final line in lines) {
      if (!line.isKnown) {
        continue;
      }
      // `unknown` è l'ultimo dell'enum: escluso qui sopra, il confronto per
      // indice basta a tenere il grado peggiore.
      if (worst == AdherenceGrade.unknown || line.grade.index > worst.index) {
        worst = line.grade;
      }
    }
    return worst;
  }
}

/// Il calcolo dell'aderenza. Puro: nessuna lettura di orologio o database.
abstract final class CoachAdherence {
  /// Sotto questi giorni di diario la settimana non si giudica: si dichiara
  /// che manca il dato. Quattro su sette è già una maggioranza.
  static const int minimumDiaryDays = 4;

  /// Calorie: entro il 7% si è centrati, entro il 15% ci si scosta.
  static const double caloriesOnTrackRatio = 0.07;
  static const double caloriesDriftingRatio = 0.15;

  /// Proteine: conta solo lo **stare sotto**. Mangiarne più del target non è
  /// un errore da segnalare durante un deficit.
  static const double proteinOnTrackRatio = 0.95;
  static const double proteinDriftingRatio = 0.85;

  /// Allenamenti: farne uno in meno su tre previsti è uno scostamento, due in
  /// meno è un'altra settimana.
  static const double workoutsOnTrackRatio = 1;
  static const double workoutsDriftingRatio = 0.6;

  static WeeklyAdherence assess({
    required CoachIntake intake,
    required int workoutsDone,
    CoachTargets? targets,
  }) {
    if (targets == null) {
      // Senza obiettivo l'app funziona lo stesso: si dice cosa si è fatto,
      // non quanto ci si è discostati da un piano che non esiste.
      return WeeklyAdherence(
        calories: AdherenceLine(
          label: 'Calorie',
          grade: AdherenceGrade.unknown,
          actual: intake.averageKcal,
          daysCounted: intake.days,
          daysExpected: 7,
          unit: 'kcal',
        ),
        protein: AdherenceLine(
          label: 'Proteine',
          grade: AdherenceGrade.unknown,
          actual: intake.averageProteinGrams,
          daysCounted: intake.days,
          daysExpected: 7,
          unit: 'g',
        ),
        workouts: workoutsDone == 0
            ? null
            : AdherenceLine(
                label: 'Allenamenti',
                grade: AdherenceGrade.unknown,
                actual: workoutsDone.toDouble(),
                daysCounted: workoutsDone,
              ),
      );
    }

    return WeeklyAdherence(
      calories: _symmetricLine(
        label: 'Calorie',
        unit: 'kcal',
        planned: targets.dailyCalories,
        actual: intake.averageKcal,
        daysCounted: intake.days,
        onTrack: caloriesOnTrackRatio,
        drifting: caloriesDriftingRatio,
      ),
      protein: _floorLine(
        label: 'Proteine',
        unit: 'g',
        planned: targets.dailyProtein,
        actual: intake.averageProteinGrams,
        daysCounted: intake.days,
        onTrack: proteinOnTrackRatio,
        drifting: proteinDriftingRatio,
      ),
      workouts: targets.weeklyWorkouts <= 0
          ? null
          : _workoutLine(planned: targets.weeklyWorkouts, done: workoutsDone),
    );
  }

  /// Riga in cui sbagliare in eccesso e in difetto pesa uguale (calorie).
  static AdherenceLine _symmetricLine({
    required String label,
    required String unit,
    required double planned,
    required double? actual,
    required int daysCounted,
    required double onTrack,
    required double drifting,
  }) {
    if (actual == null || daysCounted < minimumDiaryDays || planned <= 0) {
      return AdherenceLine.unknown(
        label: label,
        daysCounted: daysCounted,
        daysExpected: 7,
        unit: unit,
      );
    }
    final distance = ((actual - planned) / planned).abs();
    return AdherenceLine(
      label: label,
      grade: distance <= onTrack
          ? AdherenceGrade.onTrack
          : distance <= drifting
          ? AdherenceGrade.drifting
          : AdherenceGrade.off,
      planned: planned,
      actual: actual,
      daysCounted: daysCounted,
      daysExpected: 7,
      unit: unit,
    );
  }

  /// Riga con un pavimento e nessun soffitto (proteine).
  static AdherenceLine _floorLine({
    required String label,
    required String unit,
    required double planned,
    required double? actual,
    required int daysCounted,
    required double onTrack,
    required double drifting,
  }) {
    if (actual == null || daysCounted < minimumDiaryDays || planned <= 0) {
      return AdherenceLine.unknown(
        label: label,
        daysCounted: daysCounted,
        daysExpected: 7,
        unit: unit,
      );
    }
    final ratio = actual / planned;
    return AdherenceLine(
      label: label,
      grade: ratio >= onTrack
          ? AdherenceGrade.onTrack
          : ratio >= drifting
          ? AdherenceGrade.drifting
          : AdherenceGrade.off,
      planned: planned,
      actual: actual,
      daysCounted: daysCounted,
      daysExpected: 7,
      unit: unit,
    );
  }

  static AdherenceLine _workoutLine({required int planned, required int done}) {
    final ratio = done / planned;
    return AdherenceLine(
      label: 'Allenamenti',
      grade: ratio >= workoutsOnTrackRatio
          ? AdherenceGrade.onTrack
          : ratio >= workoutsDriftingRatio
          ? AdherenceGrade.drifting
          : AdherenceGrade.off,
      planned: planned.toDouble(),
      actual: done.toDouble(),
      daysCounted: done,
      daysExpected: planned,
    );
  }

  /// Quante sessioni sono state fatte in una settimana.
  static int workoutsIn(List<CoachSession> sessions, CoachWeek week) {
    var count = 0;
    for (final session in sessions) {
      if (week.contains(session.at)) {
        count++;
      }
    }
    return count;
  }
}

import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/workouts/domain/personal_records.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Una serie completata, per quel poco che serve alla forza.
///
/// È una proiezione come `CoachSession`: il coach lavora su una fotografia
/// dei dati, non sul modello vivo dell'allenamento. Qui la fotografia è
/// ancora più stretta — carico e ripetizioni — perché è tutto quello che
/// serve a [epley1Rm].
@immutable
class CoachStrengthSet {
  const CoachStrengthSet({
    required this.at,
    required this.exerciseId,
    required this.exerciseName,
    required this.weightKg,
    required this.reps,
  });

  /// Le serie che raccontano davvero la forza: completate, non riscaldamento,
  /// con carico e ripetizioni.
  ///
  /// Il raggruppamento è su [WorkoutExercise.exerciseId] e non sul nome, per
  /// la stessa ragione dei record personali: il nome è congelato nella
  /// sessione e due esercizi diversi possono chiamarsi uguale, mentre l'id
  /// originale sopravvive anche alla cancellazione dal catalogo.
  static List<CoachStrengthSet> fromWorkouts(List<Workout> workouts) => [
    for (final workout in workouts)
      for (final exercise in workout.exercises)
        for (final set in exercise.sets)
          if (set.completed && !set.isWarmup)
            if (set.weightKg case final kg? when kg > 0)
              if (set.reps case final reps? when reps > 0)
                CoachStrengthSet(
                  // La data della sessione, non quella della singola serie:
                  // le serie non ce l'hanno, e comunque un allenamento è un
                  // punto solo nel tempo.
                  at: workout.startedAt,
                  exerciseId: exercise.exerciseId,
                  exerciseName: exercise.exerciseName,
                  weightKg: kg,
                  reps: reps,
                ),
  ];

  final DateTime at;
  final String exerciseId;
  final String exerciseName;
  final double weightKg;
  final int reps;

  /// La stessa stima di Gym Tracker, non una seconda: due formule diverse per
  /// lo stesso massimale darebbero due verdetti diversi sullo stesso carico.
  double get e1rm => epley1Rm(weightKg, reps);
}

/// **Quanto è cambiata la forza sui fondamentali.** Una misura, non un
/// verdetto: la soglia oltre la quale il calo conta la mette
/// `CoachOvertraining`, che è il posto dove stanno tutte le altre.
@immutable
class StrengthTrend {
  const StrengthTrend({required this.change, required this.exercises});

  /// Nessun confronto possibile. **Non è «la forza tiene»**: senza due
  /// letture distanti tre settimane non c'è niente da confrontare, e dirlo è
  /// diverso dal rassicurare.
  const StrengthTrend.unknown() : change = null, exercises = const [];

  /// Variazione media in frazione: −0,06 vuol dire sei punti percentuali di
  /// e1RM in meno rispetto a tre settimane fa.
  final double? change;

  /// I fondamentali che si è potuto confrontare davvero, dal più frequente.
  /// Vanno detti: il numero vale solo per quegli esercizi lì.
  final List<String> exercises;

  bool get isKnown => change != null;
}

/// **La forza come misura diretta.**
///
/// Gli altri segnali del semaforo sono indizi — lo sforzo percepito, il peso
/// che scende, le proteine, l'acqua — e servono a intuire che il corpo non
/// sta reggendo. L'e1RM invece è la cosa stessa: se scende, qualcosa è già
/// successo, non sta per succedere.
abstract final class CoachStrength {
  /// La distanza fra le due letture. **Tre settimane e non una**: a una
  /// settimana il confronto è quasi tutto rumore — una notte storta, una
  /// seduta a fine giornata, un carico saltato — e il segnale ci finisce
  /// sotto. Tre settimane sono anche il tempo in cui una perdita di forza
  /// vera diventa visibile.
  static const int comparisonGapDays = 21;

  /// Quanti giorni prende ciascuna lettura. Una settimana sola non basta:
  /// Marco ruota gli esercizi e un fondamentale può saltare un turno, e una
  /// finestra senza panca non è una finestra con la panca peggiorata. Due
  /// settimane lo ripescano quasi sempre.
  static const int windowDays = 14;

  /// Quanti fondamentali si confrontano al massimo. Oltre i primi cinque si
  /// entra negli esercizi accessori, dove il carico cambia per come è
  /// costruita la scheda più che per la forza.
  static const int maxFundamentals = 5;

  /// Quanti ne servono al minimo. Sotto i tre la «media sui fondamentali» è
  /// la giornata storta di uno solo travestita da tendenza.
  static const int minimumFundamentals = 3;

  /// L'e1RM medio sui fondamentali di adesso contro quello di tre settimane
  /// fa, in frazione.
  ///
  /// [referenceDay] è la fine della settimana del rapporto e non «adesso»:
  /// rileggendo il rapporto il mercoledì le due finestre non si devono
  /// spostare da sole.
  static StrengthTrend measure({
    required List<CoachStrengthSet> sets,
    required DateTime referenceDay,
  }) {
    final currentEnd = bodyDayOf(referenceDay);
    final currentStart = currentEnd.subtract(
      const Duration(days: windowDays - 1),
    );
    final previousEnd = currentEnd.subtract(
      const Duration(days: comparisonGapDays),
    );
    final previousStart = previousEnd.subtract(
      const Duration(days: windowDays - 1),
    );

    // Il migliore e1RM di ogni giornata, esercizio per esercizio: dentro una
    // stessa seduta conta la serie di punta, non la media fra quella e le
    // serie in scarico che le stanno intorno.
    final current = <String, Map<DateTime, double>>{};
    final previous = <String, Map<DateTime, double>>{};

    // La frequenza si conta in giornate su TUTTO lo storico ricevuto, non
    // nelle due finestre: «fondamentale» è quello che Marco fa sempre, e una
    // finestra di due settimane è troppo corta per stabilirlo.
    final trainedDays = <String, Set<DateTime>>{};
    final names = <String, String>{};
    final namedAt = <String, DateTime>{};

    for (final set in sets) {
      if (set.weightKg <= 0 || set.reps <= 0) {
        continue;
      }
      final day = bodyDayOf(set.at);
      final id = set.exerciseId;
      (trainedDays[id] ??= <DateTime>{}).add(day);
      // Il nome più recente: se l'esercizio è stato rinominato, la card deve
      // dire come si chiama oggi.
      final knownAt = namedAt[id];
      if (knownAt == null || !day.isBefore(knownAt)) {
        names[id] = set.exerciseName;
        namedAt[id] = day;
      }

      final Map<String, Map<DateTime, double>> bucket;
      if (!day.isBefore(currentStart) && !day.isAfter(currentEnd)) {
        bucket = current;
      } else if (!day.isBefore(previousStart) && !day.isAfter(previousEnd)) {
        bucket = previous;
      } else {
        continue;
      }
      final byDay = bucket[id] ??= <DateTime, double>{};
      final best = byDay[day];
      final e1rm = set.e1rm;
      if (best == null || e1rm > best) {
        byDay[day] = e1rm;
      }
    }

    // Solo gli esercizi che stanno in tutte e due le finestre. Un esercizio
    // che è comparso adesso non ha un «prima» con cui confrontarsi, e uno
    // sparito non dice che la forza è calata: dice che la scheda è cambiata.
    final comparable = [
      for (final id in current.keys)
        if (previous.containsKey(id)) id,
    ];
    comparable.sort((a, b) {
      final byFrequency = (trainedDays[b]?.length ?? 0).compareTo(
        trainedDays[a]?.length ?? 0,
      );
      // A parità di frequenza decide l'id: così due esecuzioni sugli stessi
      // dati scelgono gli stessi fondamentali.
      return byFrequency != 0 ? byFrequency : a.compareTo(b);
    });

    final fundamentals = comparable.take(maxFundamentals).toList();
    if (fundamentals.length < minimumFundamentals) {
      return const StrengthTrend.unknown();
    }

    // Si media la variazione di ogni esercizio, non i chili. Mediando i
    // chili lo squat pesa il doppio della panca solo perché è più pesante, e
    // un suo mezzo chilo coprirebbe un crollo del lento avanti.
    var total = 0.0;
    for (final id in fundamentals) {
      final now = _mean(current[id]!.values);
      final before = _mean(previous[id]!.values);
      total += now / before - 1;
    }

    return StrengthTrend(
      change: total / fundamentals.length,
      exercises: [for (final id in fundamentals) names[id] ?? id],
    );
  }

  static double _mean(Iterable<double> values) {
    var total = 0.0;
    var count = 0;
    for (final value in values) {
      total += value;
      count++;
    }
    return total / count;
  }
}

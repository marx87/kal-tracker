/// Le calorie della sessione. `estimateKcal` è portata INVARIATA da Gym
/// Tracker; cambia solo da dove arriva il peso corporeo — e quello è un
/// vincolo, non un dettaglio: vedi [pickBodyKg].
library;

import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Approximate metabolic equivalent (MET) per muscle group, used to convert
/// "active session minutes" into kilocalories: kcal = MET × bodyKg × hours.
///
/// Values picked from the Compendium of Physical Activities (2011 edition),
/// rounded to one decimal. Resistance training is ~3.5–6.0 MET depending on
/// intensity; we lean a bit higher because most users overestimate intensity.
const Map<MuscleGroup, double> kMetByGroup = {
  MuscleGroup.petto: 5.0,
  MuscleGroup.schiena: 5.0,
  MuscleGroup.spalle: 5.0,
  MuscleGroup.bicipiti: 4.5,
  MuscleGroup.tricipiti: 4.5,
  MuscleGroup.gambe: 6.0,
  MuscleGroup.polpacci: 4.0,
  MuscleGroup.addome: 4.0,
  MuscleGroup.cardio: 8.0,
  MuscleGroup.fullbody: 7.0,
  MuscleGroup.mobilita: 2.5,
  MuscleGroup.altro: 5.0,
};

/// Peso di ripiego quando non esiste NESSUNA pesata. Media europea prudente:
/// serve a non produrre zero calorie, non a essere giusto.
const double kDefaultBodyKg = 70.0;

/// Quello che una sessione è costata, e con che intensità.
///
/// I due numeri escono insieme perché insieme sono stati calcolati — `kcal =
/// MET × peso × ore` — e dal solo totale non si torna indietro: senza sapere
/// per quante volte il riposo è stato moltiplicato non si può togliere, e il
/// riposo di quelle ore qualcuno lo ha già contato (il NEAT copre la giornata
/// intera). Prima il MET medio veniva calcolato e buttato alla riga dopo, e
/// chi ne aveva bisogno avrebbe dovuto rifare la media su una seconda copia
/// di [kMetByGroup].
typedef SessionEnergy = ({double kcal, double averageMet});

/// Nessun minuto attivo: niente calorie sopra il riposo, e l'intensità del
/// riposo è 1 MET per definizione.
///
/// Lo zero sarebbe più comodo e sarebbe falso: chi legge il MET per togliere
/// la quota di riposo tratta un valore sotto l'unità come un difetto a monte
/// e butta la settimana intera. Una sessione aperta e chiusa per sbaglio non
/// deve avere quel potere.
const SessionEnergy _noActiveWork = (kcal: 0, averageMet: 1);

double _metForExercise(WorkoutExercise ex, MuscleGroup group) {
  if (ex.isCooldown) return 2.5;
  if (ex.trackingMode == ExerciseTrackingMode.timed ||
      ex.trackingMode == ExerciseTrackingMode.distanceTime) {
    return 8.0; // HIIT / cardio-style
  }
  return kMetByGroup[group] ?? 5.0;
}

/// Computes the kilocalories burnt during the active part of the session.
/// **Cool-down stretches are excluded** from both the MET average and the
/// effective duration — they're low-intensity and shouldn't pad the kcal.
///
/// Realistic model: kcal ≈ avgMET × bodyKg × (activeHours)
/// Where activeHours = totalDuration − cooldownDuration.
///
/// Il MET medio esce insieme alle calorie: vedi [SessionEnergy].
SessionEnergy estimateKcal({
  required Workout workout,
  required Map<String, MuscleGroup> exerciseGroups,
  required double bodyKg,
}) {
  // Cap absurd durations (e.g. workout left open overnight) at 4 hours so a
  // bug somewhere upstream doesn't produce 1000+ kcal numbers.
  final totalMinutes = (workout.duration?.inMinutes ?? 0).clamp(0, 240);
  if (totalMinutes == 0) return _noActiveWork;

  // Estimate how many minutes of the session belonged to the cool-down so
  // we can subtract them from the active time. Each cool-down set has a
  // durationSec; sum them up and convert.
  int cooldownSeconds = 0;
  for (final ex in workout.exercises) {
    if (!ex.isCooldown) continue;
    for (final s in ex.sets) {
      cooldownSeconds += s.durationSec ?? 0;
    }
  }
  final cooldownMinutes = (cooldownSeconds / 60).round();
  final activeMinutes = (totalMinutes - cooldownMinutes).clamp(0, 240);
  if (activeMinutes == 0) return _noActiveWork;

  // Manual sessions (no tracked exercises) get a moderate 5.0 MET default,
  // like brisk circuit training.
  if (workout.exercises.isEmpty) {
    const met = 5.0;
    return (kcal: met * bodyKg * (activeMinutes / 60), averageMet: met);
  }

  // MET average across non-cool-down exercises only.
  double totalMet = 0;
  int weight = 0;
  for (final ex in workout.exercises) {
    if (ex.isCooldown) continue; // skip stretching from intensity average
    final group = exerciseGroups[ex.exerciseId] ?? MuscleGroup.altro;
    final met = _metForExercise(ex, group);
    final w = ex.sets.where((s) => s.completed).length;
    if (w == 0) continue;
    totalMet += met * w;
    weight += w;
  }
  final avgMet = weight > 0 ? totalMet / weight : 5.0;
  return (kcal: avgMet * bodyKg * (activeMinutes / 60), averageMet: avgMet);
}

/// Una pesata, ridotta a quello che serve qui.
class BodyWeightSample {
  const BodyWeightSample({required this.measuredAt, required this.kg});

  final DateTime measuredAt;
  final double kg;
}

/// Il peso con cui calcolare le calorie, e da dove viene.
///
/// QUI STA LA DIFFERENZA CON GYM TRACKER. Là la priorità 1 era
/// `UserProfile.bodyWeightKg`, un valore scritto a mano una volta e mai più
/// toccato: nell'export vale 94,7 kg mentre l'ultima pesata vera è 94,5 del
/// 19/06. Con la bilancia Renpho che scrive `body_measurements` a ogni salita,
/// leggere il campo congelato significherebbe calcolare per sempre le calorie
/// su un peso di mesi fa.
///
/// Perciò il ramo «profilo» NON esiste più: si prende sempre l'ultima pesata
/// reale. Il valore congelato di Gym resta in
/// `workout_profile_stats.gym_body_weight_kg` per spiegare i `total_kcal`
/// storici, e non va passato di qui.
///
/// [measurements] può arrivare in qualunque ordine: si sceglie la più recente
/// per `measuredAt`, non la prima della lista.
({double kg, String source}) pickBodyKg({
  required List<BodyWeightSample> measurements,
}) {
  BodyWeightSample? latest;
  for (final sample in measurements) {
    if (latest == null || sample.measuredAt.isAfter(latest.measuredAt)) {
      latest = sample;
    }
  }
  if (latest != null) {
    return (kg: latest.kg, source: 'ultima pesata');
  }
  return (kg: kDefaultBodyKg, source: 'valore di ripiego — pesati una volta');
}

/// Variante senza la stringa di provenienza, per chi deve solo calcolare.
double latestBodyKgOrDefault(List<BodyWeightSample> measurements) =>
    pickBodyKg(measurements: measurements).kg;

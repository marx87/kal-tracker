/// Il ponte fra `weeklyMuscleVolume` e la schermata.
///
/// Il dominio è una funzione pura che vuole sessioni già lette: qui gliele
/// si porta, si sceglie la settimana e si sceglie la lente con cui leggere la
/// banda. Nessun conteggio in questo file — se un numero nasce qui, è nato
/// nel posto sbagliato.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/weekly_muscle_volume.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_history_providers.dart';

/// I gruppi dell'obiettivo dichiarato: braccia, spalle e addome.
///
/// «Braccia» nel catalogo sono due gruppi separati, bicipiti e tricipiti: si
/// nominano tutt'e due o uno dei due sparirebbe dalla lista che si guarda per
/// prima.
///
/// È una COSTANTE e non un'impostazione perché oggi l'obiettivo di
/// allenamento non è scritto da nessuna parte — il profilo atleta conosce
/// attrezzi, giorni e limitazioni, non i gruppi da spingere. Un interruttore
/// che non sopravvive alla chiusura dell'app prometterebbe una scelta che non
/// esiste; una costante dichiarata si vede, e il giorno in cui il profilo avrà
/// il campo si sposta in una riga.
const Set<MuscleGroup> declaredFocusMuscleGroups = {
  MuscleGroup.spalle,
  MuscleGroup.bicipiti,
  MuscleGroup.tricipiti,
  MuscleGroup.addome,
};

/// Il lunedì della settimana in cui cade [instant], come etichetta di giorno.
///
/// Etichetta e non istante — è la stessa forma di [bodyDayOf] — perché da qui
/// in poi si sottraggono settimane: su un istante il cambio d'ora sposterebbe
/// il confine di un'ora e la sessione del lunedì alle 00:30 finirebbe nella
/// settimana prima.
DateTime startOfWeekDay(DateTime instant) {
  final day = bodyDayOf(instant);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

/// Quante settimane indietro rispetto a quella in corso. 0 è questa.
///
/// Esiste perché il lunedì mattina la settimana in corso è vuota per
/// costruzione, e una card che di lunedì non ha niente da dire è una card che
/// si impara a saltare. Non va mai sotto zero: la settimana prossima non ha
/// serie da contare, avrebbe solo zeri da far sembrare vuoti dei gruppi.
final weeklyVolumeWeekOffsetProvider = StateProvider<int>((ref) => 0);

/// Il lunedì della settimana mostrata.
final weeklyVolumeWeekStartProvider = Provider<DateTime>((ref) {
  final offset = ref.watch(weeklyVolumeWeekOffsetProvider);
  // `todayProvider` si invalida da solo a mezzanotte: la settimana avanza
  // senza che l'app venga riaperta.
  final monday = startOfWeekDay(ref.watch(todayProvider));
  return monday.subtract(Duration(days: 7 * (offset < 0 ? 0 : offset)));
});

/// La lente che l'app PROPONE, letta dalla fase dell'obiettivo.
///
/// Finché c'è un deficit il muscolo non cresce, si difende: leggere la banda
/// della crescita mentre si dimagrisce vuol dire vedere «sotto» dappertutto e
/// aggiungere serie che il recupero non regge. Senza un obiettivo attivo — e
/// nel frattempo che il piano si carica — resta il mantenimento, che è la
/// lettura che non chiede niente a nessuno.
///
/// Resta una PROPOSTA: applicarla è di Marco, con
/// [volumeIntentOverrideProvider].
final proposedVolumeIntentProvider = Provider<VolumeIntent>((ref) {
  final plan = ref.watch(goalPlanProvider).valueOrNull;
  if (plan == null || plan.dailyDeficitKcal > 0) {
    return VolumeIntent.maintenance;
  }
  return VolumeIntent.growth;
});

/// La lente scelta a mano. Nulla finché Marco non tocca niente: senza questo
/// campo la proposta si riapplicherebbe sopra una scelta già fatta ogni volta
/// che il piano ricalcola.
final volumeIntentOverrideProvider = StateProvider<VolumeIntent?>(
  (ref) => null,
);

/// La lente in uso: quella scelta, altrimenti quella proposta.
final volumeIntentProvider = Provider<VolumeIntent>(
  (ref) =>
      ref.watch(volumeIntentOverrideProvider) ??
      ref.watch(proposedVolumeIntentProvider),
);

/// Le sessioni della settimana mostrata, nella forma che il dominio conta.
///
/// Passa dallo storico e non da una query nuova: `workoutHistoryProvider` è
/// già in ascolto su sessioni, esercizi e serie, quindi la serie spuntata
/// adesso ricalcola la banda senza che nessuno riapra la schermata. Ed è la
/// stessa lista da cui escono i totali dello storico: due letture diverse
/// degli stessi allenamenti prima o poi divergono.
final weekWorkoutsProvider = FutureProvider<List<Workout>>((ref) async {
  final weekStart = ref.watch(weeklyVolumeWeekStartProvider);
  final repository = ref.watch(workoutHistoryRepositoryProvider);
  final sessions = await ref.watch(workoutHistoryProvider.future);

  final lastDay = weekStart.add(const Duration(days: 6));
  final ids = <String>[
    for (final session in sessions)
      // Taglio grossolano, e volutamente ridondante: serve solo a non aprire
      // riga per riga tutto lo storico. La finestra che decide resta quella
      // del dominio, che rifà il confronto sulle sue etichette di giorno.
      if (!_outsideWeek(bodyDayOf(session.startedAt), weekStart, lastDay))
        session.id,
  ];

  final details = await Future.wait(ids.map(repository.loadDetail));
  return [
    for (final detail in details)
      if (detail != null) _countable(detail),
  ];
});

/// La banda della settimana, pronta da mostrare.
///
/// Il conto vive separato dalla lettura: cambiare lente ricalcola una
/// funzione pura invece di rileggere il database, e la banda cambia sotto le
/// dita senza uno sfarfallio di caricamento.
final weeklyMuscleVolumeProvider = Provider<AsyncValue<WeeklyMuscleVolume>>((
  ref,
) {
  final weekStart = ref.watch(weeklyVolumeWeekStartProvider);
  final intent = ref.watch(volumeIntentProvider);
  return ref
      .watch(weekWorkoutsProvider)
      .whenData(
        (workouts) => weeklyMuscleVolume(
          workouts: workouts,
          weekStart: weekStart,
          intent: intent,
          focus: declaredFocusMuscleGroups,
        ),
      );
});

bool _outsideWeek(DateTime day, DateTime first, DateTime last) =>
    day.isBefore(first) || day.isAfter(last);

/// Il dettaglio di una sessione ridotto a ciò che il conteggio guarda.
///
/// Peso e ripetizioni NON vengono portati, ed è una scelta: qui l'unità è la
/// serie, e un `Workout` con dentro i carichi inviterebbe prima o poi a
/// sommarci il volume in chili — che è un altro numero, con un'altra regola
/// (là le serie non spuntate contano, qui no).
///
/// [WorkoutExercise.exerciseId] porta l'id della RIGA e non quello
/// dell'esercizio, che il modello di lettura non espone: al conteggio non
/// serve — non raggruppa per esercizio — ma nessuno ci costruisca sopra dei
/// record personali.
Workout _countable(WorkoutDetail detail) => Workout(
  id: detail.summary.id,
  startedAt: detail.summary.startedAt,
  endedAt: detail.summary.endedAt,
  exercises: [
    for (final exercise in detail.exercises)
      WorkoutExercise(
        exerciseId: exercise.id,
        exerciseName: exercise.name,
        muscleGroup: muscleGroupOrNull(exercise.muscleGroup),
        isWarmup: exercise.block == WorkoutBlock.warmup,
        isCooldown: exercise.block == WorkoutBlock.cooldown,
        sets: [
          for (final set in exercise.sets)
            WorkoutSet(isWarmup: set.isWarmup, completed: set.completed),
        ],
      ),
  ],
);

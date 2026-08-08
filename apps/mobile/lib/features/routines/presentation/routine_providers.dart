import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/routines/data/routine_repository.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/workouts/data/load_progression_repository.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

final routineRepositoryProvider = Provider<RoutineRepository>(
  (ref) => RoutineRepository(ref.watch(databaseProvider)),
);

final loadProgressionRepositoryProvider = Provider<LoadProgressionRepository>(
  (ref) => LoadProgressionRepository(ref.watch(databaseProvider)),
);

/// La chiave con cui si chiede [lastWorkSetsProvider]: gli id in ordine,
/// uniti da una virgola.
///
/// È una STRINGA e non un insieme perché le famiglie di Riverpod si
/// riconoscono con `==`: due `Set` con gli stessi id non sono uguali fra
/// loro, e ogni ricostruzione dell'editor avrebbe rifatto la query.
String lastWorkSetsKey(Iterable<String> exerciseRefIds) =>
    (exerciseRefIds.toSet().toList()..sort()).join(',');

/// Le serie dell'ultima seduta degli esercizi elencati nella chiave: è da
/// queste che nasce la proposta di carico della doppia progressione.
final lastWorkSetsProvider = FutureProvider.autoDispose
    .family<Map<String, List<WorkoutSet>>, String>((ref, key) async {
      // La dipendenza si dichiara prima del primo await, come negli altri
      // provider: nel buco asincrono non deve perdersi.
      final repository = ref.watch(loadProgressionRepositoryProvider);
      final profile = await ref.watch(marcoProfileProvider.future);
      return repository.lastWorkSets(
        profileId: profile.id,
        exerciseRefIds: key.isEmpty ? const <String>[] : key.split(','),
      );
    });

final routineSearchQueryProvider = StateProvider.autoDispose<String>(
  (ref) => '',
);

final routinesProvider = StreamProvider.autoDispose<List<RoutineSummary>>((
  ref,
) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* ref
      .watch(routineRepositoryProvider)
      .watchRoutines(profile.id, search: ref.watch(routineSearchQueryProvider));
});

/// La scheda aperta nell'editor. È una `Future` e non uno `Stream`: l'editor
/// lavora su una bozza propria, e un aggiornamento dal database sotto le dita
/// cancellerebbe quello che Marco sta scrivendo.
final routineDetailsProvider = FutureProvider.autoDispose
    .family<RoutineDetails?, String>(
      (ref, routineId) =>
          ref.watch(routineRepositoryProvider).getRoutine(routineId),
    );

/// Le schede che usano un esercizio, per la sua scheda di dettaglio.
final routinesUsingExerciseProvider = StreamProvider.autoDispose
    .family<List<RoutineUsage>, String>(
      (ref, exerciseId) => ref
          .watch(routineRepositoryProvider)
          .watchRoutinesUsingExercise(exerciseId),
    );

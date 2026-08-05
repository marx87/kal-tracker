import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/routines/data/routine_repository.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';

final routineRepositoryProvider = Provider<RoutineRepository>(
  (ref) => RoutineRepository(ref.watch(databaseProvider)),
);

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

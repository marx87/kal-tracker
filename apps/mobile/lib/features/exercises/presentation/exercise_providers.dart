import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/exercises/data/exercise_repository.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';

final exerciseRepositoryProvider = Provider<ExerciseRepository>(
  (ref) => ExerciseRepository(ref.watch(databaseProvider)),
);

/// Il catalogo intero, senza filtri: lo usano il selettore dell'editor e la
/// scheda di dettaglio, che non devono ereditare i filtri della lista.
final exerciseCatalogProvider = StreamProvider<List<Exercise>>((ref) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* ref.watch(exerciseRepositoryProvider).watchExercises(profile.id);
});

/// I filtri della schermata Esercizi. Sono `autoDispose`: uscendo e
/// rientrando la libreria riparte pulita, com'è successo l'ultima volta che
/// Marco l'ha lasciata a metà ricerca.
final exerciseSearchQueryProvider = StateProvider.autoDispose<String>(
  (ref) => '',
);

final exerciseMuscleFilterProvider = StateProvider.autoDispose<MuscleGroup?>(
  (ref) => null,
);

final exerciseOriginFilterProvider = StateProvider.autoDispose<ExerciseOrigin>(
  (ref) => ExerciseOrigin.all,
);

final visibleExercisesProvider = StreamProvider.autoDispose<List<Exercise>>((
  ref,
) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* ref
      .watch(exerciseRepositoryProvider)
      .watchExercises(
        profile.id,
        search: ref.watch(exerciseSearchQueryProvider),
        muscleGroup: ref.watch(exerciseMuscleFilterProvider),
        origin: ref.watch(exerciseOriginFilterProvider),
      );
});

/// Il singolo esercizio, per la schermata di dettaglio. Legge dal catalogo
/// già in memoria quando c'è, così aprire un esercizio non aspetta una query.
final exerciseDetailProvider = Provider.autoDispose.family<Exercise?, String>((
  ref,
  exerciseId,
) {
  final catalog = ref.watch(exerciseCatalogProvider).valueOrNull;
  if (catalog == null) {
    return null;
  }
  for (final exercise in catalog) {
    if (exercise.id == exerciseId) {
      return exercise;
    }
  }
  return null;
});

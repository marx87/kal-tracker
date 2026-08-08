import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/exercises/data/exercise_repository.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/training_profile/domain/exercise_screening.dart';
import 'package:kal_tracker/features/training_profile/presentation/training_profile_providers.dart';

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

/// «Mostrami solo quelli che oggi posso fare».
///
/// Parte spento, e non è un dettaglio: il catalogo che si apre è quello
/// intero, sempre. A nascondere qualcosa è un gesto di Marco, non un default
/// che gli capita addosso — e un catalogo che si accorcia da solo sembra
/// rotto.
final exercisePracticableOnlyProvider = StateProvider.autoDispose<bool>(
  (ref) => false,
);

/// Vero quando il profilo di allenamento ha davvero qualcosa da dire.
///
/// Serve a distinguere «tutto libero» da «nessuno ha ancora guardato»: senza
/// un attrezzo dichiarato e senza una limitazione aperta, lo screening
/// risponderebbe [ScreeningOutcome.libero] su tutto il catalogo, e una
/// pastiglia verde su ogni riga prometterebbe un controllo che nessuno ha
/// fatto.
final exerciseScreeningActiveProvider = Provider<bool>((ref) {
  final profile = ref.watch(trainingProfileProvider).valueOrNull;
  if (profile == null) {
    return false;
  }
  return profile.hasDeclaredEquipment || profile.activeLimitations.isNotEmpty;
});

/// **Il catalogo passato al setaccio del profilo di allenamento**, per id.
///
/// È il punto in cui attrezzatura e limitazioni smettono di essere dati che
/// si scrivono in Impostazioni e basta: qui qualcuno li rilegge e dice, riga
/// per riga, se l'esercizio è libero, se va adattato o se oggi è fuori — il
/// lavoro che il 7 agosto Marco ha fatto a mano per costruire le sue schede
/// con la spalla che non reggeva le spinte alte.
///
/// Vuoto quando il profilo tace: vedi [exerciseScreeningActiveProvider].
final exerciseScreeningsProvider = Provider<Map<String, ExerciseScreening>>((
  ref,
) {
  final profile = ref.watch(trainingProfileProvider).valueOrNull;
  final catalog = ref.watch(exerciseCatalogProvider).valueOrNull;
  if (profile == null ||
      catalog == null ||
      !ref.watch(exerciseScreeningActiveProvider)) {
    return const {};
  }
  // Sul catalogo intero e non sulla lista filtrata: la scheda di dettaglio
  // legge da qui, e non deve dipendere da cosa Marco stava cercando.
  return ExerciseScreener.screenAll(exercises: catalog, profile: profile);
});

/// L'esito di un singolo esercizio, o nullo quando il profilo tace.
final exerciseScreeningProvider = Provider.family<ExerciseScreening?, String>(
  (ref, exerciseId) => ref.watch(exerciseScreeningsProvider)[exerciseId],
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

/// Quello che la lista mostra davvero, e quanto sta tenendo fuori.
///
/// [hidden] non è un contatore per curiosi: è la dichiarazione che il filtro
/// ha tolto qualcosa. Una lista più corta senza un numero accanto sembra un
/// catalogo rotto, non un catalogo filtrato.
@immutable
class ScreenedExercises {
  const ScreenedExercises({required this.shown, required this.hidden});

  final List<Exercise> shown;
  final int hidden;
}

/// La lista della schermata: i filtri di ricerca, più il setaccio del profilo
/// quando Marco lo accende.
final screenedExercisesProvider =
    Provider.autoDispose<AsyncValue<ScreenedExercises>>((ref) {
      final exercises = ref.watch(visibleExercisesProvider);
      final practicableOnly = ref.watch(exercisePracticableOnlyProvider);
      final screenings = ref.watch(exerciseScreeningsProvider);

      return exercises.whenData((items) {
        if (!practicableOnly) {
          return ScreenedExercises(shown: items, hidden: 0);
        }
        final shown = [
          for (final exercise in items)
            // Senza esito non si toglie niente: un esercizio che lo screening
            // non ha guardato (profilo muto, catalogo non ancora arrivato) non
            // è un esercizio escluso.
            if (screenings[exercise.id]?.isExcluded != true) exercise,
        ];
        return ScreenedExercises(
          shown: shown,
          hidden: items.length - shown.length,
        );
      });
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

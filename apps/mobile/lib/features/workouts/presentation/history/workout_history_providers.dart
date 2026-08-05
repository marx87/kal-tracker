import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_repository.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_history_stats.dart';

final workoutHistoryRepositoryProvider = Provider<WorkoutHistoryRepository>(
  (ref) => WorkoutHistoryRepository(ref.watch(databaseProvider)),
);

/// Lo storico completo del profilo. Il filtro per periodo resta a valle: i
/// record personali e i totali «di sempre» hanno bisogno di tutta la storia,
/// e ricaricare il database a ogni pastiglia toccata sarebbe uno spreco.
final workoutHistoryProvider = StreamProvider<List<WorkoutSummary>>((
  ref,
) async* {
  // La watch sincrona prima del primo await: nel salto asincrono il provider
  // non deve perdere la dipendenza dal repository.
  final repository = ref.watch(workoutHistoryRepositoryProvider);
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* repository.watchHistory(profile.id);
});

/// La finestra scelta in cima alla lista.
final workoutPeriodProvider = StateProvider<WorkoutPeriod>(
  (ref) => WorkoutPeriod.month,
);

/// Il dettaglio di una sessione. `family` sull'id perché il dettaglio si apre
/// da fuori (una notifica, un link) e non solo dalla lista già caricata.
final workoutDetailProvider = StreamProvider.family<WorkoutDetail?, String>(
  (ref, workoutId) =>
      ref.watch(workoutHistoryRepositoryProvider).watchDetail(workoutId),
);

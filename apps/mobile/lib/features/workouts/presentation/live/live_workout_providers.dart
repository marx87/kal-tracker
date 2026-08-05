import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/workouts/data/drift_live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Il punto di innesto fra la sessione dal vivo e la persistenza.
///
/// Fino al collegamento dell'implementazione Drift questo provider LANCIAVA:
/// meglio una schermata che esplode di una che finge di salvare. Adesso la
/// sessione si scrive davvero, e chi vuole un falso (i test) lo sovrascrive.
///
/// Il profilo si legge in modo pigro e non con una `watch`: `marcoProfileProvider`
/// è asincrono, il repository no, e un `Provider` che dovesse aspettare il
/// profilo per esistere costringerebbe ogni schermata della palestra a
/// gestire un caricamento che dura una query.
final liveWorkoutRepositoryProvider = Provider<LiveWorkoutRepository>((ref) {
  final database = ref.watch(databaseProvider);
  return DriftLiveWorkoutRepository(
    database,
    profileId: () async => (await ref.read(marcoProfileProvider.future)).id,
  );
});

/// La sessione aperta del profilo, se c'è.
///
/// La usa sia la card «riprendi» sia il controllo prima di avviarne una nuova:
/// una sola per profilo è un indice unico del database, non una convenzione.
final activeWorkoutProvider = FutureProvider<Workout?>(
  (ref) => ref.watch(liveWorkoutRepositoryProvider).activeWorkout(),
);

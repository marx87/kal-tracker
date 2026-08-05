import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Il punto di innesto fra la sessione dal vivo e la persistenza.
///
/// Il provider non ha un valore di partenza e LANCIA se nessuno lo sovrascrive.
/// È voluto: `features/workouts/data/` la scrive un altro agente, e un finto
/// repository silenzioso qui dentro farebbe sembrare funzionante una schermata
/// che non salva niente — il modo migliore per accorgersene in palestra invece
/// che in prova.
final liveWorkoutRepositoryProvider = Provider<LiveWorkoutRepository>((ref) {
  throw UnimplementedError(
    'liveWorkoutRepositoryProvider non è stato collegato. '
    'Sovrascrivilo con l\'implementazione Drift in lib/features/workouts/data/ '
    '(o con un falso, nei test).',
  );
});

/// La sessione aperta del profilo, se c'è.
///
/// La usa sia la card «riprendi» sia il controllo prima di avviarne una nuova:
/// una sola per profilo è un indice unico del database, non una convenzione.
final activeWorkoutProvider = FutureProvider<Workout?>(
  (ref) => ref.watch(liveWorkoutRepositoryProvider).activeWorkout(),
);

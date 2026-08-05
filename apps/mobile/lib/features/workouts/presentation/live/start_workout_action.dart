/// Il pulsante che mancava: da una scheda a una sessione aperta.
///
/// Sta qui e non nella cartella delle schede perché lo stesso gesto serve in
/// tre posti — l'elenco delle schede, lo storico («rifai questa») e la card di
/// Oggi quando il piano prevede un allenamento — e in tutti e tre deve
/// comportarsi allo stesso modo, compreso il caso in cui una sessione è già
/// aperta.
///
/// **Una sola sessione per profilo è un vincolo del database**, non una
/// convenzione: `idx_workouts_one_active`. Qui il secondo avvio diventa una
/// frase con dentro un'offerta — «ne hai una aperta da 12 minuti, riprendi» —
/// invece di un'eccezione di SQLite che nessuno può leggere.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/routines/presentation/routine_providers.dart';
import 'package:kal_tracker/features/workouts/data/routine_to_workout.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/start_workout.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';

/// Apre la sessione dal vivo di [workoutId]. È una `push` e non una `go`
/// perché l'allenamento sta SOPRA la sezione da cui si è partiti: chiudendolo
/// si torna dov'era Marco, non alla radice.
void openLiveWorkout(BuildContext context, String workoutId) =>
    GoRouter.of(context).push('/workout/$workoutId');

/// Avvia una sessione dalla scheda [routineId] e la apre.
///
/// Restituisce l'esito, così chi chiama può decidere altro (i test lo leggono;
/// l'elenco delle schede no, perché il messaggio l'ha già visto l'utente).
///
/// [onOpenSession] esiste per i test e per chi non ha un router sopra di sé:
/// lasciato nullo si usa la rotta vera.
Future<StartWorkoutResult> startWorkoutFromRoutine(
  BuildContext context,
  WidgetRef ref, {
  required String routineId,
  void Function(String workoutId)? onOpenSession,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final open = onOpenSession ?? (id) => openLiveWorkout(context, id);

  final StartWorkoutResult result;
  try {
    final routine = await ref
        .read(routineRepositoryProvider)
        .getRoutine(routineId);
    if (routine == null) {
      // La scheda è stata cancellata mentre l'elenco era a schermo: dirlo è
      // più utile che aprire una sessione vuota.
      _tell(messenger, 'Questa scheda non esiste più.');
      return const WorkoutStartFailed('scheda assente');
    }
    result = await startLiveWorkout(
      ref.read(liveWorkoutRepositoryProvider),
      routineId: routine.id,
      routineName: routine.name,
      exercises: workoutExercisesFromRoutine(routine),
    );
  } catch (error) {
    _tell(messenger, 'Non sono riuscito ad aprire l\'allenamento.');
    return WorkoutStartFailed(error);
  }

  // La card «riprendi» e ogni controllo di sessione aperta leggono da qui:
  // senza questa riga resterebbero indietro di un avvio.
  ref.invalidate(activeWorkoutProvider);

  switch (result) {
    case WorkoutStarted(:final workout):
      if (context.mounted) {
        open(workout.id);
      }
    case final WorkoutAlreadyRunning running:
      // NON è un errore: è l'app chiusa a metà allenamento, e la cosa utile
      // da offrire è riprendere quella di prima.
      showAutoClosingSnackBar(
        messenger,
        SnackBar(
          content: Text(running.message(DateTime.now())),
          action: SnackBarAction(
            label: 'Riprendi',
            onPressed: () => open(running.existing.id),
          ),
        ),
      );
    case WorkoutStartFailed():
      _tell(messenger, 'Non sono riuscito ad aprire l\'allenamento.');
  }
  return result;
}

void _tell(ScaffoldMessengerState messenger, String message) {
  messenger.hideCurrentSnackBar();
  // Senza azione la snackbar si chiude da sola: l'helper serve solo a quelle
  // che ne hanno una.
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

/// «Inizia»: il pulsante da mettere accanto a una scheda.
///
/// Si disabilita mentre scrive — avviare due volte con due tocchi rapidi
/// finirebbe comunque nel messaggio «ne hai già una aperta», ma il messaggio
/// sbagliato al posto della sessione è peggio di un pulsante spento per
/// mezzo secondo.
class StartRoutineButton extends ConsumerStatefulWidget {
  const StartRoutineButton({
    required this.routineId,
    required this.routineName,
    this.onOpenSession,
    super.key,
  });

  final String routineId;

  /// Solo per l'etichetta di accessibilità: il nome che finisce nella sessione
  /// lo legge il repository dalla scheda vera, non da qui.
  final String routineName;

  final void Function(String workoutId)? onOpenSession;

  @override
  ConsumerState<StartRoutineButton> createState() => _StartRoutineButtonState();
}

class _StartRoutineButtonState extends ConsumerState<StartRoutineButton> {
  bool _starting = false;

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      await startWorkoutFromRoutine(
        context,
        ref,
        routineId: widget.routineId,
        onOpenSession: widget.onOpenSession,
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      key: Key('start_routine_${widget.routineId}'),
      onPressed: _starting ? null : () => unawaited(_start()),
      icon: _starting
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_arrow_rounded),
      // Sullo schermo basta «Inizia» — la scheda è quella lì sopra — ma un
      // lettore di schermo che scorre quattordici card sentirebbe quattordici
      // volte la stessa parola: l'etichetta parlata dice quale.
      label: Text('Inizia', semanticsLabel: 'Inizia ${widget.routineName}'),
    );
  }
}

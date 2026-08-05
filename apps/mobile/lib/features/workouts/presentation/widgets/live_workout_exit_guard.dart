import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';

/// L'uscita protetta: il gesto «indietro» non butta fuori da un allenamento
/// aperto, chiede cosa fare.
///
/// La schermata resta padrona della decisione — deve poter ATTENDERE un
/// salvataggio durevole prima di lasciar chiudere la rotta — quindi qui c'è
/// solo il `PopScope`, e il dialogo è una funzione a parte.
class LiveWorkoutExitGuard extends StatelessWidget {
  const LiveWorkoutExitGuard({
    required this.allowPop,
    required this.onExitRequested,
    required this.child,
    super.key,
  });

  /// Vero solo quando la sessione è già stata messa al sicuro: chiusa, messa
  /// in pausa e salvata, oppure mai davvero aperta.
  final bool allowPop;
  final VoidCallback onExitRequested;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) onExitRequested();
    },
    child: child,
  );
}

/// Le tre strade da un allenamento aperto.
enum WorkoutExitChoice {
  /// Torna dentro: era un gesto involontario.
  continueWorkout,

  /// Esci lasciando la sessione aperta. Il tempo lontano non conta, e dalla
  /// Home si riprende.
  pause,

  /// Chiudi e salva quello che c'è.
  finish,
}

/// Chiede cosa fare. Non è dismissibile toccando fuori: uscire per sbaglio da
/// qui è esattamente ciò che questo dialogo esiste per impedire.
Future<WorkoutExitChoice?> askWorkoutExitChoice(BuildContext context) {
  return showDialog<WorkoutExitChoice>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final accents = AppAccents.of(dialogContext);
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text(
          'Allenamento in corso',
          style: theme.textTheme.headlineSmall,
        ),
        content: Text(
          'Puoi tornare dentro, metterlo in pausa e riprenderlo dalla Home, '
          'oppure chiuderlo salvando quello che hai registrato.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: accents.mutedInk,
            height: 1.4,
          ),
        ),
        // In colonna e non in riga: tre azioni affiancate, con l'italiano e i
        // caratteri ingranditi, escono dallo schermo.
        actionsOverflowDirection: VerticalDirection.down,
        actions: [
          TextButton(
            key: const Key('workout_exit_continue'),
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(WorkoutExitChoice.continueWorkout),
            child: const Text('Continua'),
          ),
          OutlinedButton.icon(
            key: const Key('workout_exit_pause'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(WorkoutExitChoice.pause),
            icon: const Icon(Icons.pause_rounded),
            label: const Text('Metti in pausa'),
          ),
          FilledButton.icon(
            key: const Key('workout_exit_finish'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(WorkoutExitChoice.finish),
            icon: const Icon(Icons.flag_rounded),
            label: const Text('Chiudi e salva'),
          ),
        ],
      );
    },
  );
}

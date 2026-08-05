import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/today_training_providers.dart';

/// L'allenamento di oggi: quello in corso, quello previsto, o il riposo.
///
/// Una card sola con tre facce, perché la domanda è una sola — «devo
/// allenarmi adesso?» — e la risposta non cambia natura quando cambia lo
/// stato. Quando non c'è né una sessione aperta né un piano, la card non
/// viene proprio costruita: la decisione sta nella schermata Oggi.
class TodayTrainingCard extends StatelessWidget {
  const TodayTrainingCard({
    required this.training,
    required this.onResume,
    required this.onStart,
    super.key,
  });

  final TodayTraining training;

  /// Riporta alla sessione dal vivo rimasta aperta.
  final ValueChanged<OpenWorkoutSession> onResume;

  /// Porta a iniziare l'allenamento previsto.
  final ValueChanged<PlannedTraining> onStart;

  @override
  Widget build(BuildContext context) {
    final open = training.openSession;
    if (open != null) {
      return _OpenSessionCard(session: open, onResume: onResume);
    }
    final planned = training.planned;
    if (planned != null) {
      return _PlannedCard(planned: planned, onStart: onStart);
    }
    return const _RestDayCard();
  }
}

class _OpenSessionCard extends StatelessWidget {
  const _OpenSessionCard({required this.session, required this.onResume});

  final OpenWorkoutSession session;
  final ValueChanged<OpenWorkoutSession> onResume;

  @override
  Widget build(BuildContext context) {
    final started = AppTime.inRome(session.startedAt);
    final hour = started.hour.toString().padLeft(2, '0');
    final minute = started.minute.toString().padLeft(2, '0');

    return SectionCard(
      key: const Key('today_training_open'),
      title: 'Allenamento in corso',
      subtitle: session.routineName ?? 'Sessione libera',
      icon: Icons.play_circle_fill_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const StatusChip(
                level: AppStatusLevel.warning,
                label: 'Aperta',
                compact: true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Iniziata alle $hour:$minute.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const Key('today_training_resume_button'),
            onPressed: () => onResume(session),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Riprendi la sessione'),
          ),
        ],
      ),
    );
  }
}

class _PlannedCard extends StatelessWidget {
  const _PlannedCard({required this.planned, required this.onStart});

  final PlannedTraining planned;
  final ValueChanged<PlannedTraining> onStart;

  @override
  Widget build(BuildContext context) {
    final accents = AppAccents.of(context);

    return SectionCard(
      key: const Key('today_training_planned'),
      title: 'Allenamento di oggi',
      subtitle: planned.name,
      icon: Icons.fitness_center_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (planned.isMissing) ...[
            Text(
              'Questa scheda non esiste più: resta il nome che il piano '
              'aveva registrato.',
              key: const Key('today_training_missing_note'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: accents.mutedInk),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            key: const Key('today_training_start_button'),
            onPressed: () => onStart(planned),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(planned.isMissing ? 'Apri le schede' : 'Inizia'),
          ),
        ],
      ),
    );
  }
}

/// Il piano c'è e oggi non prevede niente. Il riposo è una risposta, non un
/// buco: si dice in una riga e non occupa una card intera di contenuti.
class _RestDayCard extends StatelessWidget {
  const _RestDayCard();

  @override
  Widget build(BuildContext context) {
    return const AppEmptyState(
      key: Key('today_training_rest'),
      compact: true,
      icon: Icons.self_improvement_rounded,
      message: 'Oggi il piano non prevede allenamenti: è un giorno di riposo.',
    );
  }
}

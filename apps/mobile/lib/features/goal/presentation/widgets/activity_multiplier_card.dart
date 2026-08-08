import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/goal/domain/activity_multiplier.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';
import 'package:kal_tracker/features/goal/presentation/goal_formats.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';

/// **La domanda sul moltiplicatore di attività.**
///
/// Il calcolo esisteva già e non lo leggeva nessuno: girava a vuoto dentro un
/// provider, quindi il numero che il TDEE usava restava per sempre quello
/// scelto con il dito da una tendina di cinque voci. Questa card è l'unico
/// punto in cui quel calcolo diventa una scelta di Marco.
///
/// Tre stati, e nessuno di loro applica niente da solo:
///
/// 1. gli allenamenti dicono un numero abbastanza diverso da quello in
///    vigore → si chiede, con accanto da dove viene;
/// 2. un derivato è già in vigore e non c'è niente di nuovo da chiedere → si
///    dice qual è e come si torna indietro. Senza questo il sì sarebbe una
///    porta a senso unico: `discardDerivedMultiplier` esiste dal principio e
///    non aveva nessun bottone;
/// 3. tutto il resto → niente. Il rifiuto («mi servono tre settimane»,
///    «mancano i gruppi muscolari») lo racconta già la scheda del consumo
///    qui sopra, e ripeterlo in una card sua vorrebbe dire un avviso fisso
///    che non porta a nessuna azione.
class ActivityMultiplierCard extends ConsumerStatefulWidget {
  const ActivityMultiplierCard({super.key});

  @override
  ConsumerState<ActivityMultiplierCard> createState() =>
      _ActivityMultiplierCardState();
}

class _ActivityMultiplierCardState
    extends ConsumerState<ActivityMultiplierCard> {
  /// Il numero a cui Marco ha risposto «non adesso».
  ///
  /// Si tiene il valore e non un interruttore acceso/spento: se gli
  /// allenamenti delle settimane seguenti spostano il derivato, quella è una
  /// domanda diversa e deve poter tornare. Vive quanto la schermata, e il
  /// bottone lo dice — «non adesso» non promette un silenzio per sempre, che
  /// senza un posto dove scriverlo non potremmo mantenere.
  double? _postponed;

  @override
  Widget build(BuildContext context) {
    final proposal = ref.watch(activityMultiplierProposalProvider);
    final inForce = ref.watch(acceptedActivityMultiplierProvider);
    final declared = ref.watch(activityLevelProvider);

    final derived = proposal?.proposedMultiplier;
    final question = _isPostponed(derived)
        ? null
        : proposal?.questionOver(inForce);

    final Widget? card;
    if (question != null && derived != null && proposal != null) {
      card = _Question(
        question: question,
        explanation: proposal.explanation,
        onAccept: () => _accept(derived),
        onPostpone: () => setState(() => _postponed = derived),
      );
    } else if (inForce != null) {
      card = _InForce(
        multiplier: inForce,
        declared: declared,
        onRevoke: _revoke,
      );
    } else {
      card = null;
    }

    if (card == null) {
      return const SizedBox.shrink();
    }
    // Lo stacco dalla card di sopra viaggia con la card e non nella lista:
    // il più delle volte qui non c'è niente da chiedere, e uno spazio lasciato
    // nella lista diventerebbe un buco doppio in mezzo alla schermata.
    return Padding(padding: const EdgeInsets.only(top: 14), child: card);
  }

  /// Rimandata è la domanda su QUEL numero: la stessa soglia che decide se
  /// valeva la pena chiedere decide anche se il derivato di oggi è ancora la
  /// domanda di ieri.
  bool _isPostponed(double? derived) {
    final postponed = _postponed;
    if (postponed == null || derived == null) {
      return false;
    }
    return (derived - postponed).abs() < ActivityMultiplierProposal.minimumGap;
  }

  Future<void> _accept(double multiplier) async {
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(activitySettingsProvider.notifier);
    try {
      await notifier.acceptDerivedMultiplier(multiplier);
    } on FormatException catch (error) {
      // Il rifiuto del dominio ha già le parole giuste.
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
      return;
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a salvare il consumo.')),
      );
      return;
    }
    // Un sì dato per sbaglio si disfa subito, senza andarlo a cercare: è la
    // stessa cortesia del cambio di traguardo.
    showAutoClosingSnackBar(
      messenger,
      SnackBar(
        content: const Text('Fatto: il consumo ora esce dai tuoi allenamenti.'),
        action: SnackBarAction(label: 'Annulla', onPressed: _revoke),
      ),
    );
  }

  Future<void> _revoke() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(activitySettingsProvider.notifier)
          .discardDerivedMultiplier();
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a salvare il consumo.')),
      );
    }
  }
}

class _Question extends StatelessWidget {
  const _Question({
    required this.question,
    required this.explanation,
    required this.onAccept,
    required this.onPostpone,
  });

  final String question;
  final String explanation;
  final VoidCallback onAccept;
  final VoidCallback onPostpone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SectionCard(
      key: const Key('goal_activity_proposal'),
      title: 'Gli allenamenti dicono un altro numero',
      icon: Icons.fitness_center_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            question,
            key: const Key('goal_activity_question'),
            style: theme.textTheme.titleMedium?.copyWith(height: 1.35),
          ),
          const SizedBox(height: 8),
          Text(
            explanation,
            key: const Key('goal_activity_explanation'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          // In colonna e non affiancati: a testo ingrandito «Aggiorna il
          // consumo» accanto a «Non adesso» finirebbe troncato, e un bottone
          // troncato è un bottone che non si sa cosa fa.
          FilledButton(
            key: const Key('goal_activity_accept'),
            onPressed: onAccept,
            child: const Text('Aggiorna il consumo'),
          ),
          const SizedBox(height: 6),
          TextButton(
            key: const Key('goal_activity_postpone'),
            onPressed: onPostpone,
            child: const Text('Non adesso'),
          ),
        ],
      ),
    );
  }
}

class _InForce extends StatelessWidget {
  const _InForce({
    required this.multiplier,
    required this.declared,
    required this.onRevoke,
  });

  final double multiplier;
  final ActivityLevel declared;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) => SectionCard(
    key: const Key('goal_activity_in_use'),
    title: 'Il consumo esce dai tuoi allenamenti',
    icon: Icons.fitness_center_rounded,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatRow(
          key: const Key('goal_activity_in_use_value'),
          label: 'Moltiplicatore',
          value: GoalFormats.multiplier(multiplier),
          caption:
              'al posto di «${declared.label}», che vale '
              '${GoalFormats.multiplier(declared.multiplier)}',
          icon: Icons.speed_rounded,
        ),
        const SizedBox(height: 6),
        OutlinedButton(
          key: const Key('goal_activity_revoke'),
          onPressed: onRevoke,
          child: Text('Torna a «${declared.label}»'),
        ),
      ],
    ),
  );
}

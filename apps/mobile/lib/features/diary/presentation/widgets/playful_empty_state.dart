import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';

/// L'invito di quando il diario del giorno è ancora vuoto.
///
/// È lo stato vuoto condiviso, non una card fatta in casa: prima aveva una
/// tavolozza sua di colori fissi e di notte restava chiaro su chiaro. Il
/// testo non cambia — dice cosa fare e ricorda che funziona anche senza rete.
class PlayfulDiaryEmptyState extends StatelessWidget {
  const PlayfulDiaryEmptyState({super.key});

  static const message =
      'Il diario è vuoto. Inizia con un alimento: funziona già anche senza rete.';

  @override
  Widget build(BuildContext context) {
    return const AppEmptyState(
      key: Key('diary_empty_state'),
      compact: true,
      icon: Icons.eco_rounded,
      message: message,
    );
  }
}

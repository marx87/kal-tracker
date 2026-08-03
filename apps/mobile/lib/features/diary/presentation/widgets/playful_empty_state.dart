import 'package:flutter/material.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

class PlayfulDiaryEmptyState extends StatelessWidget {
  const PlayfulDiaryEmptyState({super.key});

  static const message =
      'Il diario è vuoto. Inizia con un alimento: funziona già anche senza rete.';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: message,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppPalette.mintSoft,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppPalette.mint),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppPalette.paper,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.eco_rounded,
                  color: AppPalette.leaf,
                  size: 27,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppPalette.forestDark,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

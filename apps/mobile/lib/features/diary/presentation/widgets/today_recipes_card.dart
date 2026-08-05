import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_suggestions.dart';

/// «Cosa mangio adesso»: le ricette che ci stanno in quello che resta.
///
/// Il motore è `RecipeSuggestionEngine`, una funzione pura già testata: qui
/// non si calcola niente, si mostra il suo ordine. I numeri delle ricette
/// vengono da `NutritionCalculator` come sempre.
class TodayRecipesCard extends StatelessWidget {
  const TodayRecipesCard({
    required this.remaining,
    required this.suggestions,
    required this.onOpenRecipe,
    required this.onOpenAll,
    super.key,
  });

  /// Quante ricette si propongono. Tre: la scelta è il punto, l'elenco no —
  /// per quello c'è la scheda Ricette.
  static const int maxSuggestions = 3;

  final RemainingMacros remaining;

  /// Già ordinate dal motore. La card prende le prime che stanno nelle
  /// calorie rimaste e ignora il resto.
  final List<RecipeSuggestion> suggestions;

  final ValueChanged<String> onOpenRecipe;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final number = NumberFormat.decimalPattern('it');
    final fitting = [
      for (final suggestion in suggestions)
        if (suggestion.fitsCalories) suggestion,
    ].take(maxSuggestions).toList(growable: false);

    return SectionCard(
      key: const Key('today_recipes_card'),
      title: 'Ci stanno in quello che resta',
      subtitle:
          '${number.format(remaining.calories.round())} kcal e '
          '${remaining.protein.round()} g di proteine da qui a stasera.',
      icon: Icons.auto_awesome_rounded,
      actionLabel: 'Tutte',
      onAction: onOpenAll,
      child: fitting.isEmpty
          ? const AppEmptyState(
              key: Key('today_recipes_none'),
              compact: true,
              icon: Icons.nights_stay_rounded,
              message:
                  'Nessuna ricetta ci sta nelle calorie rimaste: meglio '
                  'qualcosa di leggero.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final suggestion in fitting)
                  _SuggestionRow(
                    suggestion: suggestion,
                    accents: accents,
                    theme: theme,
                    number: number,
                    onOpen: () => onOpenRecipe(suggestion.recipe.id),
                  ),
              ],
            ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.suggestion,
    required this.accents,
    required this.theme,
    required this.number,
    required this.onOpen,
  });

  final RecipeSuggestion suggestion;
  final AppAccents accents;
  final ThemeData theme;
  final NumberFormat number;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final serving = suggestion.recipe.nutrition.perServing;
    final detail =
        '${number.format(serving.calories.round())} kcal · '
        '${serving.protein.round()} g di proteine a porzione';

    return Semantics(
      button: true,
      container: true,
      label: '${suggestion.recipe.name}. $detail',
      child: ExcludeSemantics(
        child: InkWell(
          key: Key('today_recipe_${suggestion.recipe.id}'),
          onTap: onOpen,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.restaurant_menu_rounded,
                    size: 19,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        suggestion.recipe.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: accents.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: accents.mutedInk,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

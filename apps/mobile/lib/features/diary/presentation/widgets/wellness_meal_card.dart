import 'package:flutter/material.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';

class WellnessMealCard extends StatelessWidget {
  const WellnessMealCard({
    required this.title,
    required this.icon,
    required this.accent,
    required this.softColor,
    required this.entries,
    required this.onDelete,
    super.key,
  });

  final String title;
  final IconData icon;
  final Color accent;
  final Color softColor;
  final List<DiaryEntry> entries;
  final ValueChanged<DiaryEntry> onDelete;

  @override
  Widget build(BuildContext context) {
    final calories = entries.fold<double>(
      0,
      (sum, entry) => sum + entry.nutrients.calories,
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Semantics(
            container: true,
            header: true,
            label:
                '$title, ${calories.round()} chilocalorie, '
                '${entries.length} ${entries.length == 1 ? 'alimento' : 'alimenti'}',
            child: ExcludeSemantics(
              child: ColoredBox(
                color: softColor,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: AppPalette.paper.withValues(alpha: 0.82),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(icon, color: accent, size: 23),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: AppPalette.ink,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppPalette.paper.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            '${calories.round()} kcal',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: AppPalette.forestDark,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: softColor.withValues(alpha: 0.72),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.add_rounded, size: 19, color: accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Qui c’è ancora spazio per qualcosa di buono.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppPalette.mutedInk,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            for (var index = 0; index < entries.length; index++) ...[
              if (index > 0) const Divider(indent: 58, endIndent: 16),
              _FoodEntryTile(
                entry: entries[index],
                accent: accent,
                softColor: softColor,
                onDelete: onDelete,
              ),
            ],
        ],
      ),
    );
  }
}

class _FoodEntryTile extends StatelessWidget {
  const _FoodEntryTile({
    required this.entry,
    required this.accent,
    required this.softColor,
    required this.onDelete,
  });

  final DiaryEntry entry;
  final Color accent;
  final Color softColor;
  final ValueChanged<DiaryEntry> onDelete;

  @override
  Widget build(BuildContext context) {
    final grams = entry.grams.toStringAsFixed(entry.grams % 1 == 0 ? 0 : 1);
    return Semantics(
      container: true,
      label:
          '${entry.foodName}, $grams grammi, '
          '${entry.nutrients.calories.round()} chilocalorie',
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 5, 6, 5),
        leading: ExcludeSemantics(
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: softColor.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(Icons.restaurant_menu_rounded, size: 19, color: accent),
          ),
        ),
        title: Text(
          entry.foodName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '$grams g · P ${entry.nutrients.protein.toStringAsFixed(1)} · '
          'C ${entry.nutrients.carbs.toStringAsFixed(1)} · '
          'G ${entry.nutrients.fat.toStringAsFixed(1)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppPalette.mutedInk),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${entry.nutrients.calories.round()} kcal',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            IconButton(
              tooltip: 'Elimina ${entry.foodName}',
              onPressed: () => onDelete(entry),
              color: AppPalette.mutedInk,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

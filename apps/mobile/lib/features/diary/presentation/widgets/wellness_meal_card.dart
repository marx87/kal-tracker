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
    this.onEdit,
    this.onDuplicate,
    this.onCopyFromAnotherDay,
    this.onSaveAsTemplate,
    this.onApplyTemplate,
    this.menuKey,
    super.key,
  });

  final String title;
  final IconData icon;
  final Color accent;
  final Color softColor;
  final List<DiaryEntry> entries;
  final ValueChanged<DiaryEntry> onDelete;
  final ValueChanged<DiaryEntry>? onEdit;
  final ValueChanged<DiaryEntry>? onDuplicate;
  final VoidCallback? onCopyFromAnotherDay;
  final VoidCallback? onSaveAsTemplate;
  final VoidCallback? onApplyTemplate;
  final Key? menuKey;

  @override
  Widget build(BuildContext context) {
    final calories = entries.fold<double>(
      0,
      (sum, entry) => sum + entry.nutrients.calories,
    );
    final hasMenu =
        onCopyFromAnotherDay != null ||
        onSaveAsTemplate != null ||
        onApplyTemplate != null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ColoredBox(
            color: softColor,
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, 12, hasMenu ? 4 : 14, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      container: true,
                      header: true,
                      label:
                          '$title, ${calories.round()} chilocalorie, '
                          '${entries.length} ${entries.length == 1 ? 'alimento' : 'alimenti'}',
                      child: ExcludeSemantics(
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
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
                                  maxLines: 1,
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
                  if (hasMenu)
                    PopupMenuButton<_MealAction>(
                      key: menuKey,
                      tooltip: 'Azioni per $title',
                      icon: const Icon(Icons.more_vert_rounded),
                      color: AppPalette.paper,
                      onSelected: (action) {
                        switch (action) {
                          case _MealAction.copyDay:
                            onCopyFromAnotherDay?.call();
                          case _MealAction.applyTemplate:
                            onApplyTemplate?.call();
                          case _MealAction.saveTemplate:
                            onSaveAsTemplate?.call();
                        }
                      },
                      itemBuilder: (context) => [
                        if (onCopyFromAnotherDay != null)
                          const PopupMenuItem(
                            value: _MealAction.copyDay,
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.copy_all_rounded),
                              title: Text('Copia da un altro giorno…'),
                            ),
                          ),
                        if (onApplyTemplate != null)
                          const PopupMenuItem(
                            value: _MealAction.applyTemplate,
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.bookmark_border_rounded),
                              title: Text('Applica un modello'),
                            ),
                          ),
                        if (onSaveAsTemplate != null)
                          const PopupMenuItem(
                            value: _MealAction.saveTemplate,
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.bookmark_add_outlined),
                              title: Text('Salva come modello'),
                            ),
                          ),
                      ],
                    ),
                ],
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
                onEdit: onEdit,
                onDuplicate: onDuplicate,
              ),
            ],
        ],
      ),
    );
  }
}

enum _MealAction { copyDay, applyTemplate, saveTemplate }

enum _EntryAction { edit, duplicate, delete }

class _FoodEntryTile extends StatelessWidget {
  const _FoodEntryTile({
    required this.entry,
    required this.accent,
    required this.softColor,
    required this.onDelete,
    required this.onEdit,
    required this.onDuplicate,
  });

  final DiaryEntry entry;
  final Color accent;
  final Color softColor;
  final ValueChanged<DiaryEntry> onDelete;
  final ValueChanged<DiaryEntry>? onEdit;
  final ValueChanged<DiaryEntry>? onDuplicate;

  @override
  Widget build(BuildContext context) {
    final grams = entry.grams.toStringAsFixed(entry.grams % 1 == 0 ? 0 : 1);
    return Semantics(
      container: true,
      label:
          '${entry.foodName}, $grams grammi, '
          '${entry.nutrients.calories.round()} chilocalorie',
      child: ListTile(
        key: Key('diary_entry_${entry.id}'),
        contentPadding: const EdgeInsets.fromLTRB(14, 5, 4, 5),
        onTap: onEdit == null ? null : () => onEdit!(entry),
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
              maxLines: 1,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            PopupMenuButton<_EntryAction>(
              key: Key('entry_menu_${entry.id}'),
              tooltip: 'Azioni per ${entry.foodName}',
              color: AppPalette.paper,
              icon: const Icon(
                Icons.more_vert_rounded,
                color: AppPalette.mutedInk,
              ),
              onSelected: (action) {
                switch (action) {
                  case _EntryAction.edit:
                    onEdit?.call(entry);
                  case _EntryAction.duplicate:
                    onDuplicate?.call(entry);
                  case _EntryAction.delete:
                    onDelete(entry);
                }
              },
              itemBuilder: (context) => [
                if (onEdit != null)
                  PopupMenuItem(
                    key: Key('edit_entry_${entry.id}'),
                    value: _EntryAction.edit,
                    child: const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Modifica'),
                    ),
                  ),
                if (onDuplicate != null)
                  PopupMenuItem(
                    key: Key('duplicate_entry_${entry.id}'),
                    value: _EntryAction.duplicate,
                    child: const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.content_copy_rounded),
                      title: Text('Duplica'),
                    ),
                  ),
                PopupMenuItem(
                  key: Key('delete_entry_${entry.id}'),
                  value: _EntryAction.delete,
                  child: const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline_rounded),
                    title: Text('Elimina'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

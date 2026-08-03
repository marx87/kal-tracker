import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/meal_template.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/meal_type_presentation.dart';

class MealTemplatesSheet extends ConsumerWidget {
  const MealTemplatesSheet({required this.mealType, super.key});

  final MealType mealType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(mealTemplatesProvider);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'I tuoi modelli',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Chiudi',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              'Toccane uno per aggiungerlo a ${mealType.label.toLowerCase()}.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: templates.when(
                data: (value) => value.isEmpty
                    ? const _TemplatesEmptyState()
                    : ListView.separated(
                        key: const Key('meal_templates_list'),
                        shrinkWrap: true,
                        itemCount: value.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, index) =>
                            _TemplateTile(template: value[index]),
                      ),
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, stackTrace) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Non riesco a leggere i modelli salvati.'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TemplatesEmptyState extends StatelessWidget {
  const _TemplatesEmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: AppPalette.mintSoft,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.bookmark_border_rounded,
              color: AppPalette.forest,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Nessun modello per ora. Salva un pasto che ripeti spesso e lo '
              'ritrovi qui.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppPalette.mutedInk),
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplateTile extends ConsumerWidget {
  const _TemplateTile({required this.template});

  final MealTemplate template;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      key: Key('apply_template_${template.id}'),
      tileColor: template.mealType.softColor.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      onTap: () => Navigator.pop(context, template.id),
      leading: Icon(template.mealType.icon, color: template.mealType.accent),
      title: Text(
        template.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        '${template.items.length} '
        '${template.items.length == 1 ? 'alimento' : 'alimenti'} · '
        '${template.totals.calories.round()} kcal',
        style: const TextStyle(color: AppPalette.mutedInk),
      ),
      trailing: PopupMenuButton<_TemplateAction>(
        key: Key('template_menu_${template.id}'),
        tooltip: 'Azioni per ${template.name}',
        color: AppPalette.paper,
        icon: const Icon(Icons.more_vert_rounded, color: AppPalette.mutedInk),
        onSelected: (action) async {
          switch (action) {
            case _TemplateAction.rename:
              await _rename(context, ref);
            case _TemplateAction.delete:
              await _delete(context, ref);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            key: Key('rename_template_${template.id}'),
            value: _TemplateAction.rename,
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.drive_file_rename_outline_rounded),
              title: Text('Rinomina'),
            ),
          ),
          PopupMenuItem(
            key: Key('delete_template_${template.id}'),
            value: _TemplateAction.delete,
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline_rounded),
              title: Text('Elimina'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = await askMealTemplateName(
      context,
      title: 'Rinomina il modello',
      initialName: template.name,
    );
    if (name == null) {
      return;
    }
    try {
      await ref
          .read(mealTemplateRepositoryProvider)
          .renameTemplate(templateId: template.id, name: name);
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a rinominare il modello.')),
      );
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        key: const Key('delete_template_dialog'),
        title: Text('Elimino ${template.name}?'),
        content: const Text(
          'Sparisce dai tuoi modelli, ma le voci già nel diario restano.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: const Key('confirm_delete_template'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await ref
          .read(mealTemplateRepositoryProvider)
          .deleteTemplate(template.id);
      messenger.showSnackBar(
        SnackBar(content: Text('Modello “${template.name}” eliminato.')),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a eliminare il modello.')),
      );
    }
  }
}

enum _TemplateAction { rename, delete }

Future<String?> askMealTemplateName(
  BuildContext context, {
  required String title,
  String? initialName,
}) async {
  final name = await showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) =>
        _TemplateNameDialog(title: title, initialName: initialName ?? ''),
  );
  if (name == null || name.trim().isEmpty) {
    return null;
  }
  return name;
}

class _TemplateNameDialog extends StatefulWidget {
  const _TemplateNameDialog({required this.title, required this.initialName});

  final String title;
  final String initialName;

  @override
  State<_TemplateNameDialog> createState() => _TemplateNameDialogState();
}

class _TemplateNameDialogState extends State<_TemplateNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('template_name_field'),
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Nome del modello'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          key: const Key('confirm_template_name_button'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Salva'),
        ),
      ],
    );
  }
}

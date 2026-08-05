import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/exercises/presentation/exercise_providers.dart';
import 'package:kal_tracker/features/exercises/presentation/widgets/muscle_group_presentation.dart';

/// Apre il foglio per creare o modificare un esercizio e restituisce quello
/// salvato (nullo se Marco esce senza salvare).
///
/// Restituire l'esercizio serve al selettore delle schede: chi crea un
/// esercizio mentre sta compilando una scheda se lo ritrova già selezionato,
/// senza tornare indietro a cercarlo.
Future<Exercise?> showExerciseEditorSheet(
  BuildContext context, {
  Exercise? exercise,
  String? initialName,
  MuscleGroup? initialGroup,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final saved = await showModalBottomSheet<Exercise>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => ExerciseEditorSheet(
      exercise: exercise,
      initialName: initialName,
      initialGroup: initialGroup,
    ),
  );
  if (saved != null) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          exercise == null
              ? '«${saved.name}» è in libreria.'
              : '«${saved.name}» aggiornato.',
        ),
      ),
    );
  }
  return saved;
}

/// Il modulo di un esercizio: nome, gruppo, come si misura, note, recupero
/// predefinito e immagine.
class ExerciseEditorSheet extends ConsumerStatefulWidget {
  const ExerciseEditorSheet({
    this.exercise,
    this.initialName,
    this.initialGroup,
    super.key,
  });

  final Exercise? exercise;
  final String? initialName;
  final MuscleGroup? initialGroup;

  @override
  ConsumerState<ExerciseEditorSheet> createState() =>
      _ExerciseEditorSheetState();
}

class _ExerciseEditorSheetState extends ConsumerState<ExerciseEditorSheet> {
  late final TextEditingController _name;
  late final TextEditingController _notes;
  late final TextEditingController _imageUrl;
  late final TextEditingController _restSec;
  late MuscleGroup _group;
  late ExerciseTrackingMode _mode;
  var _saving = false;
  var _showNameError = false;

  bool get _isEditing => widget.exercise != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.exercise;
    _name = TextEditingController(
      text: existing?.name ?? widget.initialName ?? '',
    );
    _notes = TextEditingController(text: existing?.notes ?? '');
    _imageUrl = TextEditingController(text: existing?.imageUrl ?? '');
    _restSec = TextEditingController(
      text: existing?.defaultRestSec?.toString() ?? '',
    );
    _group =
        existing?.muscleGroup ?? widget.initialGroup ?? MuscleGroup.fullbody;
    _mode = existing?.trackingMode ?? ExerciseTrackingMode.weightReps;
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    _imageUrl.dispose();
    _restSec.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _showNameError = true);
      return;
    }
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final draft = ExerciseDraft(
      name: name,
      muscleGroup: _group,
      trackingMode: _mode,
      notes: _notes.text,
      imageUrl: _imageUrl.text,
      defaultRestSec: int.tryParse(_restSec.text.trim()),
    );
    try {
      final repository = ref.read(exerciseRepositoryProvider);
      final existing = widget.exercise;
      if (existing == null) {
        final profile = await ref.read(marcoProfileProvider.future);
        final created = await repository.createExercise(
          profileId: profile.id,
          draft: draft,
        );
        navigator.pop(created);
      } else {
        await repository.updateExercise(existing.id, draft);
        navigator.pop(
          Exercise(
            id: existing.id,
            name: name,
            muscleGroup: _group,
            trackingMode: _mode,
            notes: draft.notes,
            imageUrl: draft.imageUrl,
            defaultRestSec: draft.defaultRestSec,
            isPreset: existing.isPreset,
            source: existing.source,
            createdAt: existing.createdAt,
          ),
        );
      }
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Non riesco a salvare questo esercizio.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Padding(
      // La tastiera copre il pulsante Salva: il foglio le sale sopra invece
      // di lasciare il salvataggio irraggiungibile.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: const Key('exercise_editor_sheet'),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  _isEditing ? 'Modifica esercizio' : 'Nuovo esercizio',
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('exercise_name_field'),
                controller: _name,
                enabled: !_saving,
                autofocus: !_isEditing,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) {
                  if (_showNameError) {
                    setState(() => _showNameError = false);
                  }
                },
                decoration: InputDecoration(
                  labelText: 'Nome',
                  errorText: _showNameError ? 'Serve un nome.' : null,
                ),
              ),
              const SizedBox(height: 18),
              _FieldLabel(
                text: 'Gruppo muscolare',
                hint: 'Decide dove lo trovi nella libreria.',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final group in MuscleGroup.values)
                    ChoiceChip(
                      key: Key('exercise_group_${group.name}'),
                      label: Text(group.label),
                      selected: _group == group,
                      onSelected: _saving
                          ? null
                          : (_) => setState(() => _group = group),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              _FieldLabel(
                text: 'Come si misura',
                hint: 'Decide quali campi compaiono durante l\'allenamento.',
              ),
              const SizedBox(height: 8),
              for (final mode in ExerciseTrackingMode.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ModeOption(
                    mode: mode,
                    selected: _mode == mode,
                    onTap: _saving ? null : () => setState(() => _mode = mode),
                  ),
                ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('exercise_rest_field'),
                controller: _restSec,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Recupero predefinito',
                  suffixText: 'sec',
                  helperText: 'Vuoto = lo decide la scheda.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('exercise_notes_field'),
                controller: _notes,
                enabled: !_saving,
                maxLines: 3,
                maxLength: 600,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Note (facoltative)',
                  alignLabelWithHint: true,
                ),
              ),
              TextField(
                key: const Key('exercise_image_field'),
                controller: _imageUrl,
                enabled: !_saving,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Link a un\'immagine (facoltativo)',
                  helperText: 'Si vede nella scheda dell\'esercizio.',
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  MuscleGroupBadge(group: _group, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Andrà in «${_group.label}», misurato come '
                      '«${_mode.label.toLowerCase()}».',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: accents.mutedInk,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('save_exercise_button'),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_isEditing ? 'Salva le modifiche' : 'Crea'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text, this.hint});

  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: theme.textTheme.titleMedium),
        if (hint case final hint?)
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppAccents.of(context).mutedInk,
            ),
          ),
      ],
    );
  }
}

/// Una modalità di misurazione, con la sua frase di esempio. Un elenco
/// a tendina nasconderebbe proprio la parte che serve a scegliere.
class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ExerciseTrackingMode mode;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        key: Key('exercise_mode_${mode.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
              width: selected ? 1.6 : 0.8,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected
                    ? theme.colorScheme.onPrimaryContainer
                    : accents.mutedInk,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: selected
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      mode.hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: selected
                            ? theme.colorScheme.onPrimaryContainer
                            : accents.mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

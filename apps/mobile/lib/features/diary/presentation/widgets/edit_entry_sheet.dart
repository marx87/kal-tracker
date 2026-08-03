import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/diary_number_field.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/meal_type_presentation.dart';

class EditDiaryEntrySheet extends ConsumerStatefulWidget {
  const EditDiaryEntrySheet({required this.entry, super.key});

  final DiaryEntry entry;

  @override
  ConsumerState<EditDiaryEntrySheet> createState() =>
      _EditDiaryEntrySheetState();
}

class _EditDiaryEntrySheetState extends ConsumerState<EditDiaryEntrySheet> {
  final _formKey = GlobalKey<FormState>();
  final _foodName = TextEditingController();
  final _grams = TextEditingController();
  final _calories = TextEditingController();
  final _protein = TextEditingController();
  final _carbs = TextEditingController();
  final _fat = TextEditingController();
  late MealType _mealType;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _mealType = entry.mealType;
    _foodName.text = entry.foodName;
    _grams.text = editableDiaryNumber(entry.grams);
    _calories.text = editableDiaryNumber(entry.per100g.calories);
    _protein.text = editableDiaryNumber(entry.per100g.protein);
    _carbs.text = editableDiaryNumber(entry.per100g.carbs);
    _fat.text = editableDiaryNumber(entry.per100g.fat);
  }

  @override
  void dispose() {
    _foodName.dispose();
    _grams.dispose();
    _calories.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        18,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Modifica voce',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Chiudi',
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const Text('Valori nutrizionali riferiti a 100 g.'),
              const SizedBox(height: 18),
              DropdownButtonFormField<MealType>(
                key: const Key('edit_meal_type_field'),
                initialValue: _mealType,
                decoration: const InputDecoration(labelText: 'Pasto'),
                items: [
                  for (final type in MealType.values)
                    DropdownMenuItem(value: type, child: Text(type.label)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _mealType = value!),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('edit_food_name_field'),
                controller: _foodName,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Alimento'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Inserisci il nome'
                    : null,
              ),
              const SizedBox(height: 12),
              DiaryNumberField(
                key: const Key('edit_grams_field'),
                controller: _grams,
                label: 'Quantità (g)',
                mustBePositive: true,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              DiaryNumberField(
                key: const Key('edit_calories_field'),
                controller: _calories,
                label: 'Calorie per 100 g (kcal)',
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DiaryNumberField(
                      key: const Key('edit_protein_field'),
                      controller: _protein,
                      label: 'Proteine per 100 g',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DiaryNumberField(
                      key: const Key('edit_carbs_field'),
                      controller: _carbs,
                      label: 'Carboidrati per 100 g',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DiaryNumberField(
                key: const Key('edit_fat_field'),
                controller: _fat,
                label: 'Grassi per 100 g',
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 18),
              _NutritionPreview(nutrients: preview),
              const SizedBox(height: 18),
              FilledButton.icon(
                key: const Key('save_entry_button'),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_saving ? 'Salvataggio…' : 'Salva le modifiche'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Nutrients? get _preview {
    final grams = parseDiaryNumber(_grams.text);
    final calories = parseDiaryNumber(_calories.text);
    final protein = parseDiaryNumber(_protein.text);
    final carbs = parseDiaryNumber(_carbs.text);
    final fat = parseDiaryNumber(_fat.text);
    if (grams == null ||
        calories == null ||
        protein == null ||
        carbs == null ||
        fat == null) {
      return null;
    }
    try {
      return NutritionCalculator.scale(
        per100g: Nutrients(
          calories: calories,
          protein: protein,
          carbs: carbs,
          fat: fat,
        ),
        grams: grams,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(diaryRepositoryProvider)
          .updateEntry(
            itemId: widget.entry.id,
            foodName: _foodName.text,
            grams: parseDiaryNumber(_grams.text)!,
            per100g: Nutrients(
              calories: parseDiaryNumber(_calories.text)!,
              protein: parseDiaryNumber(_protein.text)!,
              carbs: parseDiaryNumber(_carbs.text)!,
              fat: parseDiaryNumber(_fat.text)!,
            ),
            mealType: _mealType,
          );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } on Object catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Non riesco a salvare le modifiche.')),
        );
      }
    }
  }
}

class _NutritionPreview extends StatelessWidget {
  const _NutritionPreview({required this.nutrients});

  final Nutrients? nutrients;

  @override
  Widget build(BuildContext context) {
    final value = nutrients;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.mintSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Con questi valori',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: AppPalette.forestDark),
            ),
            const SizedBox(height: 6),
            Text(
              key: const Key('entry_preview_calories'),
              value == null ? '— kcal' : '${value.calories.round()} kcal',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
                color: AppPalette.forestDark,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value == null
                  ? 'Completa i campi per vedere il calcolo.'
                  : 'P ${value.protein.toStringAsFixed(1)} · '
                        'C ${value.carbs.toStringAsFixed(1)} · '
                        'G ${value.fat.toStringAsFixed(1)}',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppPalette.mutedInk),
            ),
          ],
        ),
      ),
    );
  }
}

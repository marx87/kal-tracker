import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/core/updates/update_banner.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

class TodayDiaryScreen extends ConsumerWidget {
  const TodayDiaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diary = ref.watch(todayDiaryProvider);
    final today = ref.watch(todayProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Kal Tracker', style: TextStyle(fontWeight: FontWeight.w800)),
            Text('Diario di Marco', style: TextStyle(fontSize: 13)),
          ],
        ),
      ),
      body: diary.when(
        data: (value) => _DiaryBody(diary: value, day: today),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => _ErrorState(
          onRetry: () {
            ref.invalidate(marcoProfileProvider);
            ref.invalidate(todayDiaryProvider);
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_food_button'),
        onPressed: () => _showAddFoodSheet(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Aggiungi alimento'),
      ),
    );
  }

  Future<void> _showAddFoodSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const AddManualFoodSheet(),
    );
  }
}

class _DiaryBody extends ConsumerWidget {
  const _DiaryBody({required this.diary, required this.day});

  final DailyDiary diary;
  final DateTime day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formattedDay = DateFormat('EEEE d MMMM', 'it').format(day);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
      children: [
        const UpdateBanner(),
        Text(
          _capitalize(formattedDay),
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(color: Colors.black54),
        ),
        const SizedBox(height: 14),
        _SummaryCard(nutrients: diary.totals),
        const SizedBox(height: 22),
        if (diary.entries.isEmpty) const _EmptyState(),
        for (final mealType in MealType.values) ...[
          _MealSection(
            mealType: mealType,
            entries: diary.entriesFor(mealType),
            onDelete: (entry) async {
              try {
                await ref.read(diaryRepositoryProvider).deleteEntry(entry.id);
              } on Object {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Non riesco a eliminare questa voce.'),
                    ),
                  );
                }
              }
            },
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.nutrients});

  final Nutrients nutrients;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Calorie registrate',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${nutrients.calories.round()} kcal',
              key: const Key('daily_calories'),
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: colors.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _MacroValue(
                    label: 'Proteine',
                    value: nutrients.protein,
                  ),
                ),
                Expanded(
                  child: _MacroValue(
                    label: 'Carboidrati',
                    value: nutrients.carbs,
                  ),
                ),
                Expanded(
                  child: _MacroValue(label: 'Grassi', value: nutrients.fat),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MacroValue extends StatelessWidget {
  const _MacroValue({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${value.toStringAsFixed(1)} g',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _MealSection extends StatelessWidget {
  const _MealSection({
    required this.mealType,
    required this.entries,
    required this.onDelete,
  });

  final MealType mealType;
  final List<DiaryEntry> entries;
  final ValueChanged<DiaryEntry> onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(mealType.icon, size: 20),
                const SizedBox(width: 8),
                Text(
                  mealType.label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  '${entries.fold<double>(0, (sum, entry) => sum + entry.nutrients.calories).round()} kcal',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'Nessun alimento',
                  style: TextStyle(color: Colors.black45),
                ),
              )
            else
              for (final entry in entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(entry.foodName),
                  subtitle: Text(
                    '${entry.grams.toStringAsFixed(entry.grams % 1 == 0 ? 0 : 1)} g · '
                    'P ${entry.nutrients.protein.toStringAsFixed(1)} · '
                    'C ${entry.nutrients.carbs.toStringAsFixed(1)} · '
                    'G ${entry.nutrients.fat.toStringAsFixed(1)}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${entry.nutrients.calories.round()} kcal',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      IconButton(
                        tooltip: 'Elimina ${entry.foodName}',
                        onPressed: () => onDelete(entry),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.eco_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Il diario è vuoto. Inizia con un alimento: funziona già anche senza rete.',
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 44),
            const SizedBox(height: 12),
            const Text('Non riesco ad aprire il diario locale.'),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Riprova')),
          ],
        ),
      ),
    );
  }
}

class AddManualFoodSheet extends ConsumerStatefulWidget {
  const AddManualFoodSheet({super.key});

  @override
  ConsumerState<AddManualFoodSheet> createState() => _AddManualFoodSheetState();
}

class _AddManualFoodSheetState extends ConsumerState<AddManualFoodSheet> {
  final _formKey = GlobalKey<FormState>();
  final _foodName = TextEditingController();
  final _grams = TextEditingController();
  final _calories = TextEditingController();
  final _protein = TextEditingController();
  final _carbs = TextEditingController();
  final _fat = TextEditingController();
  MealType _mealType = MealType.lunch;
  bool _saving = false;

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
                      'Aggiungi alimento',
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
                key: const Key('food_name_field'),
                controller: _foodName,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Alimento'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Inserisci il nome'
                    : null,
              ),
              const SizedBox(height: 12),
              _NumberField(
                key: const Key('grams_field'),
                controller: _grams,
                label: 'Quantità (g)',
                mustBePositive: true,
              ),
              const SizedBox(height: 12),
              _NumberField(
                key: const Key('calories_field'),
                controller: _calories,
                label: 'Calorie per 100 g (kcal)',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _NumberField(
                      key: const Key('protein_field'),
                      controller: _protein,
                      label: 'Proteine per 100 g',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _NumberField(
                      key: const Key('carbs_field'),
                      controller: _carbs,
                      label: 'Carboidrati per 100 g',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _NumberField(
                key: const Key('fat_field'),
                controller: _fat,
                label: 'Grassi per 100 g',
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('save_food_button'),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_saving ? 'Salvataggio…' : 'Salva nel diario'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _saving = true);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final input = ManualFoodInput(
        foodName: _foodName.text,
        grams: _parseNumber(_grams.text)!,
        per100g: Nutrients(
          calories: _parseNumber(_calories.text)!,
          protein: _parseNumber(_protein.text)!,
          carbs: _parseNumber(_carbs.text)!,
          fat: _parseNumber(_fat.text)!,
        ),
        mealType: _mealType,
        eatenAt: AppTime.nowInRome(),
      );
      await ref
          .read(diaryRepositoryProvider)
          .addManualFood(profileId: profile.id, input: input);
      if (mounted) {
        Navigator.pop(context);
      }
    } on Object catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Non riesco a salvare questo alimento.'),
          ),
        );
      }
    }
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required super.key,
    required this.controller,
    required this.label,
    this.mustBePositive = false,
  });

  final TextEditingController controller;
  final String label;
  final bool mustBePositive;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]'))],
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(labelText: label),
      validator: (value) {
        final number = _parseNumber(value ?? '');
        if (number == null) {
          return 'Valore non valido';
        }
        if (mustBePositive ? number <= 0 : number < 0) {
          return mustBePositive ? 'Deve essere > 0' : 'Non può essere negativo';
        }
        return null;
      },
    );
  }
}

extension MealTypePresentation on MealType {
  String get label => switch (this) {
    MealType.breakfast => 'Colazione',
    MealType.lunch => 'Pranzo',
    MealType.dinner => 'Cena',
    MealType.snack => 'Spuntini',
  };

  IconData get icon => switch (this) {
    MealType.breakfast => Icons.wb_sunny_outlined,
    MealType.lunch => Icons.light_mode_outlined,
    MealType.dinner => Icons.nightlight_outlined,
    MealType.snack => Icons.eco_outlined,
  };
}

double? _parseNumber(String value) {
  final normalized = value.trim().replaceAll(',', '.');
  final parsed = double.tryParse(normalized);
  return parsed != null && parsed.isFinite ? parsed : null;
}

String _capitalize(String value) {
  if (value.isEmpty) {
    return value;
  }
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

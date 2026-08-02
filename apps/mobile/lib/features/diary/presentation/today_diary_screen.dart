import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/core/updates/update_banner.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/calorie_progress_card.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/friendly_day_header.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/playful_empty_state.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/wellness_meal_card.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/targets/presentation/target_providers.dart';

class TodayDiaryScreen extends ConsumerWidget {
  const TodayDiaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diary = ref.watch(todayDiaryProvider);
    final today = ref.watch(todayProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Kal Tracker',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: AppPalette.forestDark,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              'Diario di Marco',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
            ),
          ],
        ),
        actions: const [
          Padding(padding: EdgeInsets.only(right: 16), child: _ProfileBadge()),
        ],
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

  Future<void> _showAddFoodSheet(BuildContext context) async {
    await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const AddManualFoodSheet(),
    );
  }
}

class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Profilo di Marco',
      image: true,
      child: ExcludeSemantics(
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppPalette.mint,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: AppPalette.paper, width: 2),
          ),
          child: const Text(
            'M',
            style: TextStyle(
              color: AppPalette.forestDark,
              fontWeight: FontWeight.w900,
              fontSize: 17,
            ),
          ),
        ),
      ),
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
    final target = ref
        .watch(nutritionTargetProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => const NutritionTarget.standard(),
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const UpdateBanner(),
          const SizedBox(height: 12),
          FriendlyDayHeader(
            greeting: _greetingFor(day),
            name: 'Marco',
            dateLabel: _capitalize(formattedDay),
          ),
          const SizedBox(height: 18),
          CalorieProgressCard(
            nutrients: diary.totals,
            targetCalories: target.calories,
          ),
          const SizedBox(height: 22),
          if (diary.entries.isEmpty) ...[
            const PlayfulDiaryEmptyState(),
            const SizedBox(height: 18),
          ],
          Text('I tuoi pasti', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Tutto quello che aggiungi contribuisce al riepilogo.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppPalette.mutedInk),
          ),
          const SizedBox(height: 12),
          for (final mealType in MealType.values) ...[
            WellnessMealCard(
              title: mealType.label,
              icon: mealType.icon,
              accent: mealType.accent,
              softColor: mealType.softColor,
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
  const AddManualFoodSheet({
    this.initialFoodName,
    this.initialGrams,
    this.initialPer100g,
    this.initialMealType = MealType.lunch,
    this.onSaved,
    super.key,
  });

  final String? initialFoodName;
  final double? initialGrams;
  final Nutrients? initialPer100g;
  final MealType initialMealType;
  final Future<void> Function()? onSaved;

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
  late MealType _mealType;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _mealType = widget.initialMealType;
    _foodName.text = widget.initialFoodName ?? '';
    if (widget.initialGrams case final grams?) {
      _grams.text = _editableNumber(grams);
    }
    if (widget.initialPer100g case final nutrients?) {
      _calories.text = _editableNumber(nutrients.calories);
      _protein.text = _editableNumber(nutrients.protein);
      _carbs.text = _editableNumber(nutrients.carbs);
      _fat.text = _editableNumber(nutrients.fat);
    }
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
      await widget.onSaved?.call();
      if (mounted) {
        Navigator.pop(context, true);
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

  Color get accent => switch (this) {
    MealType.breakfast => AppPalette.yellow,
    MealType.lunch => AppPalette.coral,
    MealType.dinner => AppPalette.lilac,
    MealType.snack => AppPalette.leaf,
  };

  Color get softColor => switch (this) {
    MealType.breakfast => AppPalette.yellowSoft,
    MealType.lunch => AppPalette.coralSoft,
    MealType.dinner => AppPalette.lilacSoft,
    MealType.snack => AppPalette.mint,
  };
}

double? _parseNumber(String value) {
  final normalized = value.trim().replaceAll(',', '.');
  final parsed = double.tryParse(normalized);
  return parsed != null && parsed.isFinite ? parsed : null;
}

String _editableNumber(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');

String _capitalize(String value) {
  if (value.isEmpty) {
    return value;
  }
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

String _greetingFor(DateTime day) {
  if (day.hour < 12) {
    return 'Buongiorno';
  }
  if (day.hour < 18) {
    return 'Buon pomeriggio';
  }
  return 'Buonasera';
}

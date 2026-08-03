import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/core/updates/update_banner.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/calorie_progress_card.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/diary_number_field.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/edit_entry_sheet.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/friendly_day_header.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/meal_templates_sheet.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/meal_type_presentation.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/playful_empty_state.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/wellness_meal_card.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/targets/presentation/target_providers.dart';

export 'package:kal_tracker/features/diary/presentation/widgets/meal_type_presentation.dart';

class TodayDiaryScreen extends ConsumerWidget {
  const TodayDiaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diary = ref.watch(selectedDiaryProvider);
    final day = ref.watch(selectedDayProvider);
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
        data: (value) => _DiaryBody(diary: value, day: day, today: today),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => _ErrorState(
          onRetry: () {
            ref.invalidate(marcoProfileProvider);
            ref.invalidate(selectedDiaryProvider);
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
  const _DiaryBody({
    required this.diary,
    required this.day,
    required this.today,
  });

  final DailyDiary diary;
  final DateTime day;
  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isToday = DiaryDay.isSameDay(day, today);
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
            greeting: _greetingFor(AppTime.nowInRome()),
            name: 'Marco',
            dateLabel: diaryDayLabel(day, today),
            onPreviousDay: () => _selectDay(ref, DiaryDay.shift(day, -1)),
            onNextDay: isToday
                ? null
                : () => _selectDay(ref, DiaryDay.shift(day, 1)),
            onPickDay: () => _pickDay(context, ref),
            onBackToToday: isToday ? null : () => _selectDay(ref, today),
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
              menuKey: Key('meal_menu_${mealType.storageValue}'),
              entries: diary.entriesFor(mealType),
              onDelete: (entry) => _deleteEntry(context, ref, entry),
              onEdit: (entry) => _editEntry(context, entry),
              onDuplicate: (entry) => _duplicateEntry(context, ref, entry),
              onCopyFromAnotherDay: () => _copyMeal(context, ref, mealType),
              onSaveAsTemplate: () => _saveTemplate(context, ref, mealType),
              onApplyTemplate: () => _applyTemplate(context, ref, mealType),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  void _selectDay(WidgetRef ref, DateTime value) {
    ref.read(selectedDayProvider.notifier).state = value;
  }

  Future<void> _pickDay(BuildContext context, WidgetRef ref) async {
    final limit = DateTime(today.year - 3);
    final picked = await showDatePicker(
      context: context,
      initialDate: day,
      firstDate: day.isBefore(limit) ? day : limit,
      lastDate: today,
      locale: const Locale('it'),
      helpText: 'Scegli il giorno',
      cancelText: 'Annulla',
      confirmText: 'Vai',
    );
    if (picked != null) {
      _selectDay(ref, picked);
    }
  }

  Future<void> _editEntry(BuildContext context, DiaryEntry entry) async {
    await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => EditDiaryEntrySheet(entry: entry),
    );
  }

  Future<void> _deleteEntry(
    BuildContext context,
    WidgetRef ref,
    DiaryEntry entry,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('delete_entry_dialog'),
        title: Text('Elimino ${entry.foodName}?'),
        content: const Text(
          'Sparisce dal diario e dal totale del giorno: non si recupera.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: const Key('confirm_delete_entry'),
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
      await ref.read(diaryRepositoryProvider).deleteEntry(entry.id);
      messenger.showSnackBar(
        SnackBar(content: Text('${entry.foodName} eliminato dal diario.')),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a eliminare questa voce.')),
      );
    }
  }

  Future<void> _duplicateEntry(
    BuildContext context,
    WidgetRef ref,
    DiaryEntry entry,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final newId = await ref
          .read(diaryRepositoryProvider)
          .duplicateEntry(entry.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text('${entry.foodName} duplicato.'),
          action: SnackBarAction(
            label: 'Annulla',
            onPressed: () => _undoEntries(context, ref, [newId]),
          ),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a duplicare questa voce.')),
      );
    }
  }

  Future<void> _copyMeal(
    BuildContext context,
    WidgetRef ref,
    MealType mealType,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final initial = DiaryDay.shift(day, -1);
    final limit = DateTime(today.year - 3);
    final source = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: initial.isBefore(limit) ? initial : limit,
      lastDate: today,
      locale: const Locale('it'),
      helpText: 'Copia ${mealType.label.toLowerCase()} da…',
      cancelText: 'Annulla',
      confirmText: 'Copia',
    );
    if (source == null) {
      return;
    }
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final ids = await ref
          .read(diaryRepositoryProvider)
          .copyMeal(
            profileId: profile.id,
            fromDay: source,
            mealType: mealType,
            toDay: day,
          );
      if (ids.isEmpty) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'In quel giorno ${mealType.label.toLowerCase()} era vuoto.',
            ),
          ),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${ids.length} ${ids.length == 1 ? 'voce copiata' : 'voci copiate'}.',
          ),
          action: SnackBarAction(
            label: 'Annulla',
            onPressed: () => _undoEntries(context, ref, ids),
          ),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a copiare questo pasto.')),
      );
    }
  }

  Future<void> _saveTemplate(
    BuildContext context,
    WidgetRef ref,
    MealType mealType,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    if (diary.entriesFor(mealType).isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Aggiungi qualcosa a ${mealType.label.toLowerCase()} prima di '
            'salvare il modello.',
          ),
        ),
      );
      return;
    }
    final name = await askMealTemplateName(
      context,
      title: 'Salva come modello',
      initialName: mealType.label,
    );
    if (name == null) {
      return;
    }
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await ref
          .read(mealTemplateRepositoryProvider)
          .saveTemplateFromMeal(
            profileId: profile.id,
            day: day,
            mealType: mealType,
            name: name,
          );
      messenger.showSnackBar(
        SnackBar(content: Text('Modello “${name.trim()}” salvato.')),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a salvare questo modello.')),
      );
    }
  }

  Future<void> _applyTemplate(
    BuildContext context,
    WidgetRef ref,
    MealType mealType,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final templateId = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => MealTemplatesSheet(mealType: mealType),
    );
    if (templateId == null) {
      return;
    }
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final ids = await ref
          .read(mealTemplateRepositoryProvider)
          .applyTemplate(
            templateId: templateId,
            profileId: profile.id,
            day: day,
            mealType: mealType,
          );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Modello applicato: ${ids.length} '
            '${ids.length == 1 ? 'voce aggiunta' : 'voci aggiunte'}.',
          ),
          action: SnackBarAction(
            label: 'Annulla',
            onPressed: () => _undoEntries(context, ref, ids),
          ),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco ad applicare il modello.')),
      );
    }
  }

  Future<void> _undoEntries(
    BuildContext context,
    WidgetRef ref,
    List<String> ids,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final repository = ref.read(diaryRepositoryProvider);
    try {
      for (final id in ids) {
        await repository.deleteEntry(id);
      }
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco ad annullare l’aggiunta.')),
      );
    }
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
      _grams.text = editableDiaryNumber(grams);
    }
    if (widget.initialPer100g case final nutrients?) {
      _calories.text = editableDiaryNumber(nutrients.calories);
      _protein.text = editableDiaryNumber(nutrients.protein);
      _carbs.text = editableDiaryNumber(nutrients.carbs);
      _fat.text = editableDiaryNumber(nutrients.fat);
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
    final day = ref.watch(selectedDayProvider);
    final today = ref.watch(todayProvider);
    final isToday = DiaryDay.isSameDay(day, today);

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
              Text(
                isToday
                    ? 'Valori nutrizionali riferiti a 100 g.'
                    : 'Finisce nel diario di ${diaryDayLabel(day, today).toLowerCase()}. '
                          'Valori riferiti a 100 g.',
              ),
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
              DiaryNumberField(
                key: const Key('grams_field'),
                controller: _grams,
                label: 'Quantità (g)',
                mustBePositive: true,
              ),
              const SizedBox(height: 12),
              DiaryNumberField(
                key: const Key('calories_field'),
                controller: _calories,
                label: 'Calorie per 100 g (kcal)',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DiaryNumberField(
                      key: const Key('protein_field'),
                      controller: _protein,
                      label: 'Proteine per 100 g',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DiaryNumberField(
                      key: const Key('carbs_field'),
                      controller: _carbs,
                      label: 'Carboidrati per 100 g',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DiaryNumberField(
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
      final day = ref.read(selectedDayProvider);
      final today = ref.read(todayProvider);
      final input = ManualFoodInput(
        foodName: _foodName.text,
        grams: parseDiaryNumber(_grams.text)!,
        per100g: Nutrients(
          calories: parseDiaryNumber(_calories.text)!,
          protein: parseDiaryNumber(_protein.text)!,
          carbs: parseDiaryNumber(_carbs.text)!,
          fat: parseDiaryNumber(_fat.text)!,
        ),
        mealType: _mealType,
        eatenAt: DiaryDay.isSameDay(day, today)
            ? AppTime.nowInRome()
            : DiaryDay.instantFor(day),
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

String _capitalize(String value) {
  if (value.isEmpty) {
    return value;
  }
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

String diaryDayLabel(DateTime day, DateTime today) {
  if (DiaryDay.isSameDay(day, today)) {
    return 'Oggi';
  }
  if (DiaryDay.isSameDay(day, DiaryDay.shift(today, -1))) {
    return 'Ieri';
  }
  if (DiaryDay.isSameDay(day, DiaryDay.shift(today, 1))) {
    return 'Domani';
  }
  return _capitalize(DateFormat('EEEE d MMMM', 'it').format(day));
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

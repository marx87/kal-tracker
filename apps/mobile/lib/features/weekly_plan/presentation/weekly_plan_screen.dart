import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/presentation/snackbars.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_providers.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/targets/presentation/target_providers.dart';
import 'package:kal_tracker/features/weekly_plan/data/plan_nutrition.dart';
import 'package:kal_tracker/features/weekly_plan/data/weekly_plan_repository.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/weekly_plan_providers.dart';

/// Schermata "Piano" (quinta voce della barra).
///
/// Tre stati, mai bloccanti:
/// * nessun piano → le caselle dei pasti, i giorni, la data di inizio e le
///   note: "Genera il piano" accoda il lavoro al Mac;
/// * in attesa → si può uscire e tornare, il piano vecchio resta leggibile;
/// * piano pronto → i giorni in fila con i valori CALCOLATI dall'app dalle
///   ricette reali, il confronto col target e il pulsante "Fatto" che porta
///   la porzione nel diario del giorno e del pasto giusti.
///
/// Nessun numero arriva dal modello: kcal e macro escono sempre da
/// [PlanNutrition] a partire dalle ricette di Marco.
class WeeklyPlanScreen extends ConsumerStatefulWidget {
  const WeeklyPlanScreen({super.key});

  @override
  ConsumerState<WeeklyPlanScreen> createState() => _WeeklyPlanScreenState();
}

class _WeeklyPlanScreenState extends ConsumerState<WeeklyPlanScreen> {
  static const List<int> _dayOptions = [3, 5, 7, 14];

  final TextEditingController _notes = TextEditingController();
  final Set<PlanMeal> _meals = {
    PlanMeal.colazione,
    PlanMeal.pranzo,
    PlanMeal.cena,
  };
  int _days = 7;
  DateTime? _startDate;

  /// Null finché Marco non decide: il modulo si apre da solo solo quando non
  /// c'è niente da mostrare.
  bool? _formOpen;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  DateTime get _tomorrow =>
      PlanDate.addDays(PlanDate.normalize(AppTime.nowInRome()), 1);

  @override
  Widget build(BuildContext context) {
    final plan = ref.watch(activeWeeklyPlanProvider);
    final pending = ref.watch(pendingWeeklyPlanProvider);
    final failed = ref.watch(failedWeeklyPlanProvider);
    final ui = ref.watch(weeklyPlanControllerProvider);
    final recipes =
        ref.watch(recipesProvider).valueOrNull ?? const <FitRecipeSummary>[];
    final target =
        ref.watch(nutritionTargetProvider).valueOrNull ??
        const NutritionTarget.standard();
    final recipesById = {for (final recipe in recipes) recipe.id: recipe};
    final formOpen = _formOpen ?? (plan == null && pending == null);

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Piano'),
            Text(
              'La settimana, decisa una volta sola',
              style: TextStyle(
                color: AppPalette.mutedInk,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('weekly_plan_shopping_button'),
            tooltip: 'Lista della spesa',
            onPressed: () => context.goNamed('plan-shopping'),
            icon: const Icon(Icons.shopping_basket_outlined),
          ),
        ],
      ),
      body: ListView(
        key: const Key('weekly_plan_list'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          // Il messaggio d'errore sta dove Marco ha appena toccato: dentro il
          // modulo se è aperto, in cima alla lista se il modulo è chiuso.
          if (ui.error case final message? when !formOpen) ...[
            _MessageCard(
              key: const Key('weekly_plan_error'),
              icon: Icons.error_outline_rounded,
              color: AppPalette.coralSoft,
              iconColor: AppPalette.coral,
              title: 'Non ci siamo',
              message: message,
            ),
            const SizedBox(height: 12),
          ],
          if (pending != null) ...[
            const _MessageCard(
              key: Key('plan_generating_card'),
              icon: Icons.hourglass_top_rounded,
              color: AppPalette.yellowSoft,
              iconColor: AppPalette.yellow,
              title: 'Il Mac sta preparando il piano',
              message:
                  'Ci vuole qualche minuto. Puoi uscire e tornare: appena è '
                  'pronto lo trovi qui. Se il Mac è spento non arriverà '
                  'nulla, e te lo dirò senza girarci intorno.',
            ),
            const SizedBox(height: 12),
          ],
          if (failed != null && pending == null) ...[
            _MessageCard(
              key: const Key('plan_failed_card'),
              icon: Icons.cloud_off_rounded,
              color: AppPalette.coralSoft,
              iconColor: AppPalette.coral,
              title: 'Piano non arrivato',
              message:
                  failed.notes ??
                  'Il Mac non ha risposto: riprova quando è acceso.',
              action: OutlinedButton.icon(
                key: const Key('plan_retry_button'),
                onPressed: () => setState(() => _formOpen = true),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Riprova'),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (formOpen) ...[
            _PlanForm(
              meals: _meals,
              days: _days,
              dayOptions: _dayOptions,
              startDate: _startDate ?? _tomorrow,
              notes: _notes,
              error: ui.error,
              busy: ui.busy,
              waiting: pending != null,
              canClose: plan != null,
              onMealToggled: _toggleMeal,
              onDaysChanged: (value) => setState(() => _days = value),
              onPickStartDate: _pickStartDate,
              onGenerate: _generate,
              onClose: () => setState(() => _formOpen = false),
            ),
            const SizedBox(height: 12),
          ],
          if (plan != null)
            ..._planSections(
              plan: plan,
              recipesById: recipesById,
              target: target,
              busySlotId: ui.busySlotId,
              formOpen: formOpen,
            ),
        ],
      ),
    );
  }

  List<Widget> _planSections({
    required WeeklyPlan plan,
    required Map<String, FitRecipeSummary> recipesById,
    required NutritionTarget target,
    required String? busySlotId,
    required bool formOpen,
  }) {
    return [
      _PlanHeader(
        plan: plan,
        showNewPlanButton: !formOpen,
        onShoppingList: () => context.goNamed('plan-shopping'),
        onNewPlan: () => setState(() => _formOpen = true),
      ),
      for (final date in plan.dates)
        _PlanDay(
          date: date,
          slots: plan.slotsFor(date),
          recipesById: recipesById,
          target: target,
          busySlotId: busySlotId,
          onDone: _markDone,
          onUndo: _undo,
          onReplace: _replace,
          onOpenRecipe: _openRecipe,
        ),
    ];
  }

  void _toggleMeal(PlanMeal meal, bool selected) {
    setState(() {
      if (selected) {
        _meals.add(meal);
      } else {
        _meals.remove(meal);
      }
    });
  }

  Future<void> _pickStartDate() async {
    final today = PlanDate.normalize(AppTime.nowInRome());
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? _tomorrow,
      firstDate: today,
      lastDate: PlanDate.addDays(today, 90),
      helpText: 'Da quando parte il piano',
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() => _startDate = PlanDate.normalize(picked));
  }

  Future<void> _generate() async {
    final messenger = ScaffoldMessenger.of(context);
    final generated = await ref
        .read(weeklyPlanControllerProvider.notifier)
        .generate(
          startDate: _startDate ?? _tomorrow,
          days: _days,
          meals: _meals,
          notes: _notes.text,
        );
    if (!mounted || !generated) {
      return;
    }
    setState(() => _formOpen = false);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Richiesta inviata al Mac: ti avviso appena è pronto.'),
      ),
    );
  }

  Future<void> _markDone(WeeklyPlanSlot slot) async {
    final messenger = ScaffoldMessenger.of(context);
    final done = await ref
        .read(weeklyPlanControllerProvider.notifier)
        .markDone(slot);
    if (!mounted) {
      return;
    }
    if (!done) {
      _showFailure(messenger);
      return;
    }
    showAutoClosingSnackBar(
      messenger,
      SnackBar(
        content: Text(
          '${slot.recipeName} nel diario di ${_dayLabel(slot.date)}.',
        ),
        action: SnackBarAction(
          label: 'Annulla',
          onPressed: () => unawaited(
            ref.read(weeklyPlanControllerProvider.notifier).undo(slot),
          ),
        ),
      ),
    );
  }

  Future<void> _undo(WeeklyPlanSlot slot) async {
    final messenger = ScaffoldMessenger.of(context);
    final undone = await ref
        .read(weeklyPlanControllerProvider.notifier)
        .undo(slot);
    if (mounted && !undone) {
      _showFailure(messenger);
    }
  }

  /// Le azioni sugli slot avvengono lontano dal modulo: il motivo del rifiuto
  /// viaggia in snackbar, dove si vede subito.
  void _showFailure(ScaffoldMessengerState messenger) {
    final message = ref.read(weeklyPlanControllerProvider).error;
    if (message == null) {
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Sostituzione manuale: prima le ricette con il tag di quel pasto, poi
  /// tutte le altre. Solo ricette REALI del ricettario, come per l'AI.
  Future<void> _replace(WeeklyPlanSlot slot) async {
    final recipes =
        ref.read(recipesProvider).valueOrNull ?? const <FitRecipeSummary>[];
    if (recipes.isEmpty) {
      return;
    }
    final tag = slot.meal.storageValue;
    final matching = [
      for (final recipe in recipes)
        if (recipe.tags.contains(tag)) recipe,
    ];
    final others = [
      for (final recipe in recipes)
        if (!recipe.tags.contains(tag)) recipe,
    ];
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ReplaceSheet(
        meal: slot.meal,
        suggested: matching,
        others: others,
        currentRecipeId: slot.recipeId,
      ),
    );
    if (chosen == null || !mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final replaced = await ref
        .read(weeklyPlanControllerProvider.notifier)
        .replace(slot, chosen);
    if (mounted && !replaced) {
      _showFailure(messenger);
    }
  }

  void _openRecipe(WeeklyPlanSlot slot) {
    final recipeId = slot.recipeId;
    if (recipeId == null) {
      return;
    }
    // `go` e non `push`: il dettaglio ricetta vive nel ramo Ricette, e da un
    // altro ramo un push finirebbe in un navigator non visibile.
    context.goNamed('recipe-details', pathParameters: {'recipeId': recipeId});
  }
}

class _PlanForm extends StatelessWidget {
  const _PlanForm({
    required this.meals,
    required this.days,
    required this.dayOptions,
    required this.startDate,
    required this.notes,
    required this.error,
    required this.busy,
    required this.waiting,
    required this.canClose,
    required this.onMealToggled,
    required this.onDaysChanged,
    required this.onPickStartDate,
    required this.onGenerate,
    required this.onClose,
  });

  final Set<PlanMeal> meals;
  final int days;
  final List<int> dayOptions;
  final DateTime startDate;
  final TextEditingController notes;

  /// Messaggio dell'ultimo tentativo andato male, mostrato accanto al
  /// pulsante: è lì che Marco sta guardando.
  final String? error;
  final bool busy;
  final bool waiting;
  final bool canClose;
  final void Function(PlanMeal meal, bool selected) onMealToggled;
  final ValueChanged<int> onDaysChanged;
  final Future<void> Function() onPickStartDate;
  final Future<void> Function() onGenerate;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ready = meals.isNotEmpty && !busy && !waiting;
    return Card(
      key: const Key('weekly_plan_form'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Prepariamo la settimana',
                    key: const Key('weekly_plan_form_title'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (canClose)
                  IconButton(
                    key: const Key('plan_form_close_button'),
                    tooltip: 'Chiudi',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Scegli cosa pianificare: il piano lo prepara il Mac usando '
              'solo le tue ricette.',
              style: TextStyle(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 14),
            Text(
              'Quali pasti?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final meal in PlanMeal.values)
              CheckboxListTile(
                key: Key('plan_meal_${meal.storageValue}'),
                value: meals.contains(meal),
                onChanged: (value) => onMealToggled(meal, value ?? false),
                title: Text(meal.label),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: AppPalette.forest,
              ),
            const SizedBox(height: 6),
            Text(
              'Quanti giorni?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in dayOptions)
                  ChoiceChip(
                    key: Key('plan_days_$option'),
                    label: Text('$option giorni'),
                    selected: days == option,
                    onSelected: (_) => onDaysChanged(option),
                    selectedColor: AppPalette.mint,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text('Da quando?', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('plan_start_date_button'),
              onPressed: () => unawaited(onPickStartDate()),
              icon: const Icon(Icons.event_rounded),
              label: Text(_capitalize(_dayLabel(startDate))),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('plan_notes_field'),
              controller: notes,
              maxLines: 2,
              maxLength: WeeklyPlanRequest.maxNotesLength,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Note per il Mac (facoltative)',
                hintText: 'Es. niente funghi, poco tempo infrasettimanale',
              ),
            ),
            if (meals.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Scegli almeno un pasto da pianificare.',
                  style: TextStyle(color: AppPalette.coral),
                ),
              ),
            if (error case final message?)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  key: const Key('weekly_plan_error'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 18,
                      color: AppPalette.coral,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        message,
                        style: const TextStyle(color: AppPalette.coral),
                      ),
                    ),
                  ],
                ),
              ),
            FilledButton.icon(
              key: const Key('generate_plan_button'),
              onPressed: ready ? () => unawaited(onGenerate()) : null,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_rounded),
              label: Text(busy ? 'Invio al Mac…' : 'Genera il piano'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanHeader extends StatelessWidget {
  const _PlanHeader({
    required this.plan,
    required this.showNewPlanButton,
    required this.onShoppingList,
    required this.onNewPlan,
  });

  final WeeklyPlan plan;
  final bool showNewPlanButton;
  final VoidCallback onShoppingList;
  final VoidCallback onNewPlan;

  @override
  Widget build(BuildContext context) {
    final last = PlanDate.addDays(plan.startDate, plan.days - 1);
    return Card(
      key: const Key('weekly_plan_header'),
      color: AppPalette.mintSoft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Il tuo piano di ${plan.days} giorni',
              key: const Key('weekly_plan_title'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Da ${_dayLabel(plan.startDate)} a ${_dayLabel(last)}',
              style: const TextStyle(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 4),
            Text(
              plan.slots.isEmpty
                  ? 'Nessun pasto pianificato.'
                  : '${plan.doneCount} di ${plan.slots.length} pasti già nel '
                        'diario.',
              key: const Key('weekly_plan_progress'),
              style: const TextStyle(color: AppPalette.mutedInk),
            ),
            if (plan.notes case final notes?) ...[
              const SizedBox(height: 10),
              Row(
                key: const Key('weekly_plan_notes'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 18,
                    color: AppPalette.lilac,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      notes,
                      style: const TextStyle(
                        color: AppPalette.mutedInk,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const Key('open_shopping_list'),
                  onPressed: onShoppingList,
                  icon: const Icon(Icons.shopping_basket_rounded),
                  label: const Text('Lista della spesa'),
                ),
                if (showNewPlanButton)
                  OutlinedButton.icon(
                    key: const Key('new_plan_button'),
                    onPressed: onNewPlan,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Nuovo piano'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanDay extends StatelessWidget {
  const _PlanDay({
    required this.date,
    required this.slots,
    required this.recipesById,
    required this.target,
    required this.busySlotId,
    required this.onDone,
    required this.onUndo,
    required this.onReplace,
    required this.onOpenRecipe,
  });

  final DateTime date;
  final List<WeeklyPlanSlot> slots;
  final Map<String, FitRecipeSummary> recipesById;
  final NutritionTarget target;
  final String? busySlotId;
  final Future<void> Function(WeeklyPlanSlot slot) onDone;
  final Future<void> Function(WeeklyPlanSlot slot) onUndo;
  final Future<void> Function(WeeklyPlanSlot slot) onReplace;
  final void Function(WeeklyPlanSlot slot) onOpenRecipe;

  @override
  Widget build(BuildContext context) {
    final iso = PlanDate.format(date);
    final total = PlanNutrition.sum([
      for (final slot in slots)
        if (_perServing(slot) case final perServing?)
          PlanNutrition.forServings(
            perServing: perServing,
            servings: slot.servings,
          ),
    ]);
    final reached = total.calories >= target.calories * 0.9;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                _capitalize(_dayLabel(date)),
                key: Key('plan_day_$iso'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Text(
              '${_round(total.calories)} / ${_round(target.calories)} kcal',
              key: Key('plan_day_total_$iso'),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: reached ? AppPalette.forest : AppPalette.mutedInk,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (slots.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'Niente in programma: giornata libera.',
              style: TextStyle(color: AppPalette.mutedInk),
            ),
          ),
        for (final slot in slots)
          _PlanSlotCard(
            slot: slot,
            perServing: _perServing(slot),
            busy: busySlotId == slot.id,
            locked: busySlotId != null && busySlotId != slot.id,
            onDone: () => unawaited(onDone(slot)),
            onUndo: () => unawaited(onUndo(slot)),
            onReplace: () => unawaited(onReplace(slot)),
            onOpenRecipe: () => onOpenRecipe(slot),
          ),
      ],
    );
  }

  /// Valori per porzione della ricetta REALE; null se non è più nel
  /// ricettario (allora non si mostra alcun numero, mai uno inventato).
  Nutrients? _perServing(WeeklyPlanSlot slot) {
    final recipeId = slot.recipeId;
    if (recipeId == null) {
      return null;
    }
    return recipesById[recipeId]?.nutrition.perServing;
  }
}

class _PlanSlotCard extends StatelessWidget {
  const _PlanSlotCard({
    required this.slot,
    required this.perServing,
    required this.busy,
    required this.locked,
    required this.onDone,
    required this.onUndo,
    required this.onReplace,
    required this.onOpenRecipe,
  });

  final WeeklyPlanSlot slot;
  final Nutrients? perServing;
  final bool busy;
  final bool locked;
  final VoidCallback onDone;
  final VoidCallback onUndo;
  final VoidCallback onReplace;
  final VoidCallback onOpenRecipe;

  @override
  Widget build(BuildContext context) {
    final available = slot.hasRecipe && perServing != null;
    final nutrients = perServing == null
        ? null
        : PlanNutrition.forServings(
            perServing: perServing!,
            servings: slot.servings,
          );

    return Card(
      key: Key('plan_slot_${slot.id}'),
      color: slot.isDone ? AppPalette.mintSoft : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slot.meal.label.toUpperCase(),
                        style: const TextStyle(
                          color: AppPalette.leaf,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        slot.recipeName,
                        key: Key('plan_slot_recipe_${slot.id}'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                if (slot.isDone)
                  const Icon(
                    Icons.check_circle_rounded,
                    color: AppPalette.leaf,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              nutrients == null
                  ? '${planServingsLabel(slot.servings)} · valori non '
                        'disponibili'
                  : '${planServingsLabel(slot.servings)} · '
                        '${_round(nutrients.calories)} kcal · '
                        'P ${nutrients.protein.toStringAsFixed(1)} · '
                        'C ${nutrients.carbs.toStringAsFixed(1)} · '
                        'G ${nutrients.fat.toStringAsFixed(1)}',
              key: Key('plan_slot_macros_${slot.id}'),
              style: const TextStyle(color: AppPalette.mutedInk),
            ),
            if (!available) ...[
              const SizedBox(height: 6),
              Text(
                'Questa ricetta non è più nel ricettario: sostituiscila.',
                key: Key('plan_slot_missing_${slot.id}'),
                style: const TextStyle(color: AppPalette.coral),
              ),
            ],
            if (slot.why case final why?) ...[
              const SizedBox(height: 8),
              Row(
                key: Key('plan_slot_why_${slot.id}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 16,
                    color: AppPalette.lilac,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      why,
                      style: const TextStyle(
                        color: AppPalette.mutedInk,
                        fontStyle: FontStyle.italic,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (slot.isDone)
                  TextButton.icon(
                    key: Key('plan_slot_undo_${slot.id}'),
                    onPressed: busy || locked ? null : onUndo,
                    icon: const Icon(Icons.undo_rounded, size: 18),
                    label: const Text('Annulla'),
                  )
                else
                  FilledButton.icon(
                    key: Key('plan_slot_done_${slot.id}'),
                    onPressed: !available || busy || locked ? null : onDone,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Fatto'),
                  ),
                TextButton.icon(
                  key: Key('plan_slot_replace_${slot.id}'),
                  onPressed: slot.isDone || busy || locked ? null : onReplace,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: const Text('Sostituisci'),
                ),
                if (slot.hasRecipe)
                  TextButton.icon(
                    key: Key('plan_slot_open_${slot.id}'),
                    onPressed: onOpenRecipe,
                    icon: const Icon(Icons.menu_book_rounded, size: 18),
                    label: const Text('Ricetta'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Scelta manuale della ricetta di uno slot: solo ricette del ricettario.
class _ReplaceSheet extends StatelessWidget {
  const _ReplaceSheet({
    required this.meal,
    required this.suggested,
    required this.others,
    required this.currentRecipeId,
  });

  final PlanMeal meal;
  final List<FitRecipeSummary> suggested;
  final List<FitRecipeSummary> others;
  final String? currentRecipeId;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        key: const Key('plan_replace_sheet'),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
        shrinkWrap: true,
        children: [
          Text(
            'Cosa metti a ${meal.label.toLowerCase()}?',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          const Text(
            'Solo ricette del tuo ricettario.',
            style: TextStyle(color: AppPalette.mutedInk),
          ),
          const SizedBox(height: 10),
          for (final recipe in [...suggested, ...others])
            ListTile(
              key: Key('plan_replace_option_${recipe.id}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                recipe.id == currentRecipeId
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: AppPalette.leaf,
              ),
              title: Text(recipe.name),
              subtitle: Text(
                '${_round(recipe.nutrition.perServing.calories)} kcal a '
                'porzione',
              ),
              onTap: () => Navigator.of(context).pop(recipe.id),
            ),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.icon,
    required this.color,
    required this.iconColor,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final Color color;
  final Color iconColor;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(message),
                  if (action case final action?) ...[
                    const SizedBox(height: 10),
                    action,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _dayLabel(DateTime date) => DateFormat('EEEE d MMMM', 'it').format(date);

String _capitalize(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

String _round(double value) =>
    NumberFormat.decimalPattern('it').format(value.round());

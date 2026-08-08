import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_providers.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/targets/presentation/target_providers.dart';
import 'package:kal_tracker/features/weekly_plan/data/plan_nutrition.dart';
import 'package:kal_tracker/features/weekly_plan/data/weekly_plan_repository.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_week.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_workout_start.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/weekly_plan_providers.dart';

/// Schermata "Piano" (quinta voce della barra): UNA settimana, non due.
///
/// Ogni giorno mostra quello che ha — i pasti previsti e l'allenamento
/// previsto — perché è così che si vive un mercoledì. Le due metà però
/// nascono in posti diversi e restano indipendenti: i pasti li compone il Mac
/// (`weekly_plan_slots`), gli allenamenti vengono dalla settimana delle schede
/// (`routine_weekly_plan`) e ci sono anche quando il piano dei pasti non
/// c'è ancora.
///
/// Tre stati, mai bloccanti:
/// * nessun piano → le caselle dei pasti, i giorni, la data di inizio e le
///   note: "Genera il piano" accoda il lavoro al Mac. Sotto, gli allenamenti
///   della settimana restano visibili;
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
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final plan = ref.watch(activeWeeklyPlanProvider);
    final pending = ref.watch(pendingWeeklyPlanProvider);
    final failed = ref.watch(failedWeeklyPlanProvider);
    final ui = ref.watch(weeklyPlanControllerProvider);
    final week = ref.watch(planWeekProvider);
    final recipes =
        ref.watch(recipesProvider).valueOrNull ?? const <FitRecipeSummary>[];
    final target =
        ref.watch(effectiveNutritionTargetProvider).valueOrNull ??
        const NutritionTarget.standard();
    final recipesById = {for (final recipe in recipes) recipe.id: recipe};
    final formOpen = _formOpen ?? (plan == null && pending == null);
    // Senza piano dei pasti una fila di giorni vuoti non direbbe niente: si
    // mostrano solo quelli che hanno un allenamento.
    final days = plan == null
        ? [
            for (final day in week)
              if (!day.isEmpty) day,
          ]
        : week;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Piano'),
            Text(
              'La settimana, pasti e allenamenti',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
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
      // La testata (moduli e messaggi) resta una colonna leggibile e centrata,
      // ma i GIORNI no: sette giorni incolonnati su un tablet sono sette
      // schermate di scorrimento per vedere una settimana che è UNA cosa
      // sola. Da `medium` in su i giorni vanno a due per riga — si leggono
      // ancora nell'ordine naturale (lun-mar, mer-gio…) e la settimana si
      // abbraccia in un colpo d'occhio.
      body: AdaptiveLayout(
        builder: (context, size) => AdaptiveContent(
          child: ListView(
            key: const Key('weekly_plan_list'),
            padding: AppBreakpoints.pagePadding(size),
            children: [
              // Il messaggio d'errore sta dove Marco ha appena toccato: dentro
              // il modulo se è aperto, in cima alla lista se è chiuso.
              if (ui.error case final message? when !formOpen) ...[
                _MessageCard(
                  key: const Key('weekly_plan_error'),
                  icon: Icons.error_outline_rounded,
                  color: accents.criticalSurface,
                  iconColor: accents.critical,
                  title: 'Non ci siamo',
                  message: message,
                ),
                const SizedBox(height: 12),
              ],
              if (pending != null) ...[
                _MessageCard(
                  key: const Key('plan_generating_card'),
                  icon: Icons.hourglass_top_rounded,
                  color: accents.warningSurface,
                  iconColor: accents.warning,
                  title: 'Il Mac sta preparando il piano',
                  message:
                      'Ci vuole qualche minuto. Puoi uscire e tornare: appena '
                      'è pronto lo trovi qui. Se il Mac è spento non arriverà '
                      'nulla, e te lo dirò senza girarci intorno.',
                ),
                const SizedBox(height: 12),
              ],
              if (failed != null && pending == null) ...[
                _MessageCard(
                  key: const Key('plan_failed_card'),
                  icon: Icons.cloud_off_rounded,
                  color: accents.criticalSurface,
                  iconColor: accents.critical,
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
                _PlanHeader(
                  plan: plan,
                  showNewPlanButton: !formOpen,
                  onShoppingList: () => context.goNamed('plan-shopping'),
                  onNewPlan: () => setState(() => _formOpen = true),
                ),
              // Senza piano dei pasti la settimana è solo palestra: si dice,
              // così l'elenco che segue non sembra un piano a metà.
              if (plan == null && days.isNotEmpty) ...[
                const SizedBox(height: 6),
                _WorkoutsOnlyIntro(count: days.length),
              ],
              ..._weekRows(size, [
                for (final day in days)
                  _PlanDay(
                    day: day,
                    recipesById: recipesById,
                    target: target,
                    showTotals: plan != null,
                    busySlotId: ui.busySlotId,
                    canStartWorkout:
                        ref.watch(planWorkoutStarterProvider) != null,
                    onDone: _markDone,
                    onUndo: _undo,
                    onReplace: _replace,
                    onOpenRecipe: _openRecipe,
                    onStartWorkout: _startWorkout,
                  ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  /// I giorni: uno sotto l'altro sul telefono, due per riga da `medium` in su.
  ///
  /// Le coppie seguono il calendario (lunedì accanto a martedì, non due
  /// colonne indipendenti da leggere in verticale): l'ordine di lettura resta
  /// quello con cui si vive la settimana.
  List<Widget> _weekRows(AppWindowSize size, List<Widget> days) {
    if (size.isCompact) {
      return days;
    }
    final gutter = AppBreakpoints.gutter(size);
    return [
      for (var index = 0; index < days.length; index += 2)
        Row(
          // I giorni hanno altezze diverse (chi ha l'allenamento, chi tre
          // pasti): si allineano in alto, non si stirano l'uno sull'altro.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: days[index]),
            SizedBox(width: gutter),
            // Con un numero dispari di giorni l'ultimo resta largo come gli
            // altri invece di prendersi tutta la riga.
            Expanded(
              child: index + 1 < days.length
                  ? days[index + 1]
                  : const SizedBox.shrink(),
            ),
          ],
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

  /// Avvia la sessione del giorno, o porta alla scheda se non c'è ancora chi
  /// sa aprirla (vedi `planWorkoutStarterProvider`).
  Future<void> _startWorkout(PlannedWorkout workout) async {
    final routineId = workout.routineId;
    if (routineId == null) {
      return;
    }
    final starter = ref.read(planWorkoutStarterProvider);
    if (starter == null) {
      // La scheda vive nel ramo Palestra: `go`, non `push`.
      context.goNamed('routine-edit', pathParameters: {'routineId': routineId});
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final result = await starter(routineId);
    if (!mounted) {
      return;
    }
    switch (result) {
      case PlanWorkoutRunning(:final workoutId, :final resumed):
        if (resumed) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Avevi già una sessione aperta: riprendo quella.'),
            ),
          );
        }
        // A schermo intero e fuori dalla shell: in palestra il telefono
        // mostra una cosa sola.
        await context.pushNamed(
          'workout-live',
          pathParameters: {'workoutId': workoutId},
        );
      case PlanWorkoutNotStarted(:final message):
        messenger.showSnackBar(SnackBar(content: Text(message)));
    }
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
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
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
                    style: theme.textTheme.titleLarge,
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
            Text(
              'Scegli cosa pianificare: il piano lo prepara il Mac usando '
              'solo le tue ricette, e tiene conto dei giorni in cui ti alleni.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
              ),
            ),
            const SizedBox(height: 14),
            Text('Quali pasti?', style: theme.textTheme.titleMedium),
            for (final meal in PlanMeal.values)
              CheckboxListTile(
                key: Key('plan_meal_${meal.storageValue}'),
                value: meals.contains(meal),
                onChanged: (value) => onMealToggled(meal, value ?? false),
                title: Text(meal.label),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: theme.colorScheme.primary,
              ),
            const SizedBox(height: 6),
            Text('Quanti giorni?', style: theme.textTheme.titleMedium),
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
                    selectedColor: theme.colorScheme.primaryContainer,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text('Da quando?', style: theme.textTheme.titleMedium),
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
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Scegli almeno un pasto da pianificare.',
                  style: TextStyle(color: accents.critical),
                ),
              ),
            if (error case final message?)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  key: const Key('weekly_plan_error'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 18,
                      color: accents.critical,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        message,
                        style: TextStyle(color: accents.critical),
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
    final theme = Theme.of(context);
    final last = PlanDate.addDays(plan.startDate, plan.days - 1);
    return Card(
      key: const Key('weekly_plan_header'),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Il tuo piano di ${plan.days} giorni',
              key: const Key('weekly_plan_title'),
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Da ${_dayLabel(plan.startDate)} a ${_dayLabel(last)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              plan.slots.isEmpty
                  ? 'Nessun pasto pianificato.'
                  : '${plan.doneCount} di ${plan.slots.length} pasti già nel '
                        'diario.',
              key: const Key('weekly_plan_progress'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            if (plan.notes case final notes?) ...[
              const SizedBox(height: 10),
              Row(
                key: const Key('weekly_plan_notes'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 18,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      notes,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
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

/// Cappello dell'elenco quando il piano dei pasti non c'è ancora.
class _WorkoutsOnlyIntro extends StatelessWidget {
  const _WorkoutsOnlyIntro({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('plan_workouts_only_intro'),
      padding: const EdgeInsets.only(top: 6),
      child: AppEmptyState(
        compact: true,
        icon: Icons.fitness_center_rounded,
        message: count == 1
            ? 'Il piano dei pasti non c’è ancora, ma un allenamento in '
                  'settimana sì: eccolo.'
            : 'Il piano dei pasti non c’è ancora, ma gli allenamenti della '
                  'settimana sì: eccoli.',
      ),
    );
  }
}

/// Una giornata: il titolo, l'allenamento previsto e i pasti previsti.
class _PlanDay extends StatelessWidget {
  const _PlanDay({
    required this.day,
    required this.recipesById,
    required this.target,
    required this.showTotals,
    required this.busySlotId,
    required this.canStartWorkout,
    required this.onDone,
    required this.onUndo,
    required this.onReplace,
    required this.onOpenRecipe,
    required this.onStartWorkout,
  });

  final PlanWeekDay day;
  final Map<String, FitRecipeSummary> recipesById;
  final NutritionTarget target;

  /// Il confronto col target ha senso solo dove i pasti sono pianificati: in
  /// una settimana di soli allenamenti «0 / 2.000 kcal» sarebbe un giudizio
  /// su un dato che non esiste.
  final bool showTotals;

  final String? busySlotId;
  final bool canStartWorkout;
  final Future<void> Function(WeeklyPlanSlot slot) onDone;
  final Future<void> Function(WeeklyPlanSlot slot) onUndo;
  final Future<void> Function(WeeklyPlanSlot slot) onReplace;
  final void Function(WeeklyPlanSlot slot) onOpenRecipe;
  final Future<void> Function(PlannedWorkout workout) onStartWorkout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final iso = PlanDate.format(day.date);
    final slots = day.meals;
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
                _capitalize(_dayLabel(day.date)),
                key: Key('plan_day_$iso'),
                style: theme.textTheme.titleLarge,
              ),
            ),
            if (showTotals)
              Text(
                '${_round(total.calories)} / ${_round(target.calories)} kcal',
                key: Key('plan_day_total_$iso'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: reached ? accents.positive : accents.mutedInk,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (day.workout case final workout?)
          _WorkoutCard(
            date: day.date,
            workout: workout,
            canStart: canStartWorkout,
            onStart: () => unawaited(onStartWorkout(workout)),
          )
        else if (showTotals)
          Padding(
            key: Key('plan_rest_$iso'),
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(Icons.bedtime_outlined, size: 16, color: accents.mutedInk),
                const SizedBox(width: 6),
                // A caratteri ingranditi la frase va a capo invece di
                // sfondare la riga.
                Expanded(
                  child: Text(
                    'Riposo: nessun allenamento previsto.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: accents.mutedInk,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (day.workout != null && slots.isNotEmpty) const SizedBox(height: 10),
        if (slots.isEmpty && showTotals)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              'Niente in programma: giornata libera.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
              ),
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

/// L'allenamento previsto del giorno, con la sua unica azione.
class _WorkoutCard extends StatelessWidget {
  const _WorkoutCard({
    required this.date,
    required this.workout,
    required this.canStart,
    required this.onStart,
  });

  final DateTime date;
  final PlannedWorkout workout;

  /// Vero quando qualcuno sa aprire davvero la sessione: altrimenti il
  /// pulsante non promette un allenamento, porta alla scheda.
  final bool canStart;

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final iso = PlanDate.format(date);
    final detail = [
      if (workout.isCircuit) 'circuito',
      if (workout.exerciseCount == 1)
        '1 esercizio'
      else if (workout.exerciseCount > 1)
        '${workout.exerciseCount} esercizi',
    ].join(' · ');

    return Card(
      key: Key('plan_workout_$iso'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: workout.isCircuit
                        ? accents.warningSurface
                        : theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(
                    workout.isCircuit
                        ? Icons.bolt_rounded
                        : Icons.fitness_center_rounded,
                    size: 21,
                    color: workout.isCircuit
                        ? accents.warning
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ALLENAMENTO',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: accents.positive,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        workout.routineName,
                        key: Key('plan_workout_name_$iso'),
                        style: theme.textTheme.titleMedium,
                      ),
                      if (detail.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: accents.mutedInk,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (workout.isMissing) ...[
              const SizedBox(height: 8),
              Text(
                'Questa scheda non è più nel tuo elenco: era prevista qui.',
                key: Key('plan_workout_missing_$iso'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: accents.critical,
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                key: Key('plan_workout_start_$iso'),
                onPressed: onStart,
                icon: Icon(
                  canStart
                      ? Icons.play_arrow_rounded
                      : Icons.assignment_outlined,
                ),
                label: Text(canStart ? 'Inizia allenamento' : 'Apri la scheda'),
              ),
            ],
          ],
        ),
      ),
    );
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
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final available = slot.hasRecipe && perServing != null;
    final nutrients = perServing == null
        ? null
        : PlanNutrition.forServings(
            perServing: perServing!,
            servings: slot.servings,
          );

    return Card(
      key: Key('plan_slot_${slot.id}'),
      color: slot.isDone ? theme.colorScheme.primaryContainer : null,
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
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: accents.positive,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        slot.recipeName,
                        key: Key('plan_slot_recipe_${slot.id}'),
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                if (slot.isDone)
                  Icon(Icons.check_circle_rounded, color: accents.positive),
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
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
              ),
            ),
            if (!available) ...[
              const SizedBox(height: 6),
              Text(
                'Questa ricetta non è più nel ricettario: sostituiscila.',
                key: Key('plan_slot_missing_${slot.id}'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: accents.critical,
                ),
              ),
            ],
            if (slot.why case final why?) ...[
              const SizedBox(height: 8),
              Row(
                key: Key('plan_slot_why_${slot.id}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 16,
                    color: accents.info,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      why,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: accents.mutedInk,
                        fontStyle: FontStyle.italic,
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
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    // Anche il foglio nasce largo quanto la finestra: l'elenco delle ricette
    // si legge in colonna, non da un bordo all'altro del tablet.
    return SafeArea(
      child: AdaptiveContent(
        child: ListView(
          key: const Key('plan_replace_sheet'),
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
          shrinkWrap: true,
          children: [
            Text(
              'Cosa metti a ${meal.label.toLowerCase()}?',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Solo ricette del tuo ricettario.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
              ),
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
                  color: theme.colorScheme.primary,
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
    final theme = Theme.of(context);
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
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(message, style: theme.textTheme.bodyMedium),
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

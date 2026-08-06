import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/core/updates/update_banner.dart';
import 'package:kal_tracker/features/body/presentation/body_screen.dart';
import 'package:kal_tracker/features/checkin/presentation/morning_check_in_card.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/today_training_providers.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/calorie_progress_card.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/diary_number_field.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/edit_entry_sheet.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/friendly_day_header.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/meal_templates_sheet.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/meal_type_presentation.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/playful_empty_state.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/today_recipes_card.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/today_training_card.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/water_intake_card.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/wellness_meal_card.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_repository.dart';
import 'package:kal_tracker/features/photo_meal/domain/photo_meal_job.dart';
import 'package:kal_tracker/features/photo_meal/presentation/meal_analysis_result.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_proposals_listener.dart';
import 'package:kal_tracker/features/quick_add/photo_meal_launcher.dart';
import 'package:kal_tracker/features/quick_add/quick_add_menu.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_providers.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/targets/presentation/target_providers.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';

export 'package:kal_tracker/features/diary/presentation/widgets/meal_type_presentation.dart';

/// Quanto spazio si lascia in fondo alla lista.
///
/// Il FAB esteso galleggia sopra il contenuto e non lo spinge: senza questa
/// riserva l'ultima cosa scritta — lo stato vuoto compreso — finisce sotto
/// «Aggiungi alimento». Sono i 56 del FAB, i 16 del suo margine e un po' di
/// respiro perché il testo non arrivi a sfiorarlo.
const double kDiaryBottomClearance = 56 + 16 + 40;

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
              'Coach360',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            Text(
              'Diario di Marco',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppAccents.of(context).mutedInk,
              ),
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
        onPressed: () => _openQuickAddMenu(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Aggiungi alimento'),
      ),
    );
  }

  /// Menu smart del FAB: manuale, catalogo, foto o codice a barre.
  /// La voce manuale riapre lo stesso sheet di sempre: un tap in più,
  /// ma le altre strade sono a portata di pollice.
  Future<void> _openQuickAddMenu(BuildContext context, WidgetRef ref) async {
    final action = await showQuickAddMenu(context);
    if (action == null || !context.mounted) {
      return;
    }
    switch (action) {
      case QuickAddAction.manual:
        await _showAddFoodSheet(context);
      case QuickAddAction.catalog:
        // Il ritorno rapido al diario è la tab «Oggi», sempre visibile.
        GoRouter.of(context).go('/foods');
      case QuickAddAction.photo:
        await _startPhotoFlow(context, ref);
      case QuickAddAction.barcode:
        await GoRouter.of(context).push('/barcode-scan');
    }
  }

  /// La foto dal menu smart non ha un pasto di contesto: si chiede prima.
  /// Stessi guard del pulsante sotto i pasti: mai un crash offline.
  Future<void> _startPhotoFlow(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!ref.read(appConfigProvider).hasSupabaseConfiguration) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'La foto del pasto non è attiva su questa installazione: puoi '
            'aggiungere a mano, dal catalogo o col codice a barre.',
          ),
        ),
      );
      return;
    }
    final mealType = await showQuickAddMealPicker(context);
    if (mealType == null || !context.mounted) {
      return;
    }
    await startPhotoMealCapture(
      context: context,
      ref: ref,
      mealType: mealType,
      day: ref.read(selectedDayProvider),
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
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Profilo di Marco',
      image: true,
      child: ExcludeSemantics(
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: scheme.surfaceContainerLowest, width: 2),
          ),
          child: Text(
            'M',
            style: TextStyle(
              color: scheme.onPrimaryContainer,
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

    // Oggi non è una lista di testo lungo: è una pila di card che rispondono
    // a due domande diverse — «come sta andando la giornata» e «cosa ho
    // mangiato». Su un tablet largo una colonna sola e centrata risponderebbe
    // a una domanda alla volta lasciando mezzo schermo vuoto, quindi da
    // `expanded` in su le due domande stanno affiancate: a sinistra il
    // riepilogo e le azioni di adesso, a destra il diario dei pasti.
    //
    // Su `medium` (tablet in verticale) due colonne scenderebbero sotto i 400
    // punti l'una nella parte bassa della taglia: l'anello delle calorie
    // accanto al «ti restano», e i tre pulsanti dell'acqua in fila, ci
    // starebbero a stento. Lì basta una colonna sola, centrata e limitata.
    //
    // La misura arriva da `AdaptiveLayout`, non da `MediaQuery`: qui dentro
    // c'è già la guida laterale che si mangia la sua fetta di schermo.
    return AdaptiveLayout(
      builder: (context, size) {
        final padding = AppBreakpoints.pagePadding(size);
        final header = _header(context, ref, isToday: isToday);
        final meals = _mealCards(context, ref);

        if (size.isExpanded) {
          return _TwoColumnDiary(
            padding: padding,
            gutter: AppBreakpoints.gutter(size),
            header: header,
            summary: _summaryCards(
              context,
              ref,
              target: target,
              isToday: isToday,
            ),
            meals: [
              // A due colonne l'invito a cominciare apre la colonna dei
              // pasti: è lì che il vuoto si vede, ed è lì che il FAB
              // «Aggiungi alimento» galleggia.
              if (diary.entries.isEmpty) ...[
                const PlayfulDiaryEmptyState(),
                const SizedBox(height: 14),
              ],
              ...meals,
            ],
          );
        }

        return AdaptiveContent(
          child: SingleChildScrollView(
            key: const Key('diary_single_column'),
            // La riserva per il FAB si somma ai margini di pagina: il FAB
            // galleggia sopra il contenuto e non lo spinge.
            padding: padding.copyWith(
              bottom: padding.bottom + kDiaryBottomClearance,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                const SizedBox(height: 18),
                ..._summaryCards(
                  context,
                  ref,
                  target: target,
                  isToday: isToday,
                  // In colonna unica lo stato vuoto sta QUI e non in fondo: è
                  // l'invito a cominciare, e in fondo alla lista finirebbe
                  // fuori dal primo schermo, dietro al FAB.
                  emptyState: diary.entries.isEmpty
                      ? const PlayfulDiaryEmptyState()
                      : null,
                ),
                const SizedBox(height: 22),
                ...meals,
              ],
            ),
          ),
        );
      },
    );
  }

  /// Il saluto e il giorno scelto. Comanda tutto quello che sta sotto — le
  /// due colonne comprese — quindi non appartiene a nessuna delle due.
  Widget _header(
    BuildContext context,
    WidgetRef ref, {
    required bool isToday,
  }) => Column(
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
    ],
  );

  /// Come sta andando la giornata: quanto resta, cosa c'è da fare adesso.
  List<Widget> _summaryCards(
    BuildContext context,
    WidgetRef ref, {
    required NutritionTarget target,
    required bool isToday,
    Widget? emptyState,
  }) => [
    // A diario vuoto l'invito viene PRIMA di tutto, anche dell'anello.
    //
    // Stava sotto, ed era la scelta giusta finché la card delle calorie era
    // più bassa: da quando le proteine hanno una riga tutta loro, su un
    // telefono da 844 punti l'invito è scivolato dietro al FAB. Un invito a
    // cominciare coperto dal bottone per cominciare è il peggiore dei mondi,
    // e comunque a zero calorie l'anello non ha niente da dire che l'invito
    // non dica meglio.
    if (emptyState != null) ...[emptyState, const SizedBox(height: 14)],
    // Quanto resta. È la prima domanda della giornata e l'unica che vale la
    // pena leggere da lontano.
    CalorieProgressCard(nutrients: diary.totals, target: target),
    // Le tre card del «adesso» valgono solo per oggi: guardando ieri
    // sono rumore, e l'allenamento di ieri non si inizia più.
    if (isToday) ...[
      const _TodayTrainingSection(),
      const _TodayRecipesSection(),
      const SizedBox(height: 14),
      MorningCheckInCard(onWeighIn: () => openWeighInSheet(context, ref)),
    ],
    const SizedBox(height: 14),
    // L'acqua segue il giorno selezionato come tutto il resto del diario.
    WaterIntakeCard(
      day: day,
      today: today,
      dayLabel: diaryDayLabel(day, today),
    ),
  ];

  /// Cosa ho mangiato: l'intestazione della sezione e i quattro pasti.
  List<Widget> _mealCards(BuildContext context, WidgetRef ref) => [
    Text('I tuoi pasti', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 4),
    Text(
      'Tutto quello che aggiungi contribuisce al riepilogo.',
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(color: AppAccents.of(context).mutedInk),
    ),
    const SizedBox(height: 12),
    // Punto d'ingresso stabile alla revisione: la snackbar dura 8
    // secondi, il badge resta finché ci sono proposte pronte.
    const PhotoProposalsBadge(),
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
      _PhotoMealSection(mealType: mealType, day: day),
      const SizedBox(height: 12),
    ],
  ];

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
          'Sparisce dal diario e dal totale del giorno. Se cambi idea, '
          'puoi annullare subito dopo.',
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
      showAutoClosingSnackBar(
        messenger,
        SnackBar(
          content: Text('${entry.foodName} eliminato dal diario.'),
          action: SnackBarAction(
            label: 'Annulla',
            onPressed: () => _restoreEntry(context, ref, entry),
          ),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a eliminare questa voce.')),
      );
    }
  }

  Future<void> _restoreEntry(
    BuildContext context,
    WidgetRef ref,
    DiaryEntry entry,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(diaryRepositoryProvider).restoreEntry(entry.id);
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a ripristinare la voce.')),
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
      showAutoClosingSnackBar(
        messenger,
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
      showAutoClosingSnackBar(
        messenger,
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
      showAutoClosingSnackBar(
        messenger,
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

/// Oltre questa larghezza le due colonne smetterebbero di essere leggibili:
/// sono due colonne di contenuto piene più il corridoio fra loro. Sul tablet
/// di Marco (1706 punti, meno la guida laterale) non morde: serve a non far
/// degenerare la schermata su un monitor.
final double _twoColumnMaxWidth =
    AppBreakpoints.contentMaxWidth(AppWindowSize.expanded) * 2 +
    AppBreakpoints.gutter(AppWindowSize.expanded);

/// Il diario su schermo largo: riepilogo a sinistra, pasti a destra.
///
/// Le due colonne scorrono separate di proposito. Sono lunghe in modo molto
/// diverso — il riepilogo è corto, i pasti crescono con la giornata — e
/// scorrendo i pasti si vuole tenere sotto gli occhi quante calorie e quante
/// proteine restano: è il motivo per cui si guarda questa schermata.
///
/// Il FAB «Aggiungi alimento» resta in basso a destra, cioè sopra la colonna
/// dei pasti: è esattamente dove finisce quello che aggiunge. Per questo la
/// riserva in fondo ([kDiaryBottomClearance]) tocca solo quella colonna.
class _TwoColumnDiary extends StatelessWidget {
  const _TwoColumnDiary({
    required this.padding,
    required this.gutter,
    required this.header,
    required this.summary,
    required this.meals,
  });

  final EdgeInsets padding;
  final double gutter;
  final Widget header;
  final List<Widget> summary;
  final List<Widget> meals;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _twoColumnMaxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // L'intestazione non scorre con nessuna delle due colonne: il
            // giorno scelto vale per entrambe, e chi scorre i pasti deve
            // continuare a vedere di che giorno sta parlando.
            Padding(
              padding: EdgeInsets.fromLTRB(
                padding.left,
                padding.top,
                padding.right,
                0,
              ),
              child: header,
            ),
            SizedBox(height: gutter),
            Expanded(
              child: Row(
                // `stretch` e non `start`: così ogni colonna riceve
                // l'altezza della finestra e scorre dentro di sé, invece di
                // traboccare.
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const Key('diary_summary_column'),
                      padding: EdgeInsets.fromLTRB(
                        padding.left,
                        0,
                        0,
                        padding.bottom,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: summary,
                      ),
                    ),
                  ),
                  SizedBox(width: gutter),
                  Expanded(
                    child: SingleChildScrollView(
                      key: const Key('diary_meals_column'),
                      padding: EdgeInsets.fromLTRB(
                        0,
                        0,
                        padding.right,
                        padding.bottom + kDiaryBottomClearance,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: meals,
                      ),
                    ),
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

/// L'allenamento di oggi, quando c'è qualcosa da dire.
///
/// Legge lo stato e basta: se la lettura fallisce la sezione sparisce invece
/// di piantare un errore in mezzo al diario. La palestra è un'informazione in
/// più su questa schermata, non la sua ragione d'essere.
class _TodayTrainingSection extends ConsumerWidget {
  const _TodayTrainingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final training = ref.watch(todayTrainingProvider).valueOrNull;
    if (training == null || training.isSilent) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: TodayTrainingCard(
        training: training,
        onResume: (session) => _resumeWorkout(context, ref, session),
        onStart: (_) => _openGym(context),
      ),
    );
  }
}

/// Riprende la sessione aperta.
///
/// `liveWorkoutRepositoryProvider` non è ancora collegato all'app — lancia
/// finché qualcuno non lo sovrascrive con l'implementazione Drift — e la
/// schermata dal vivo lo legge in `initState`. Senza questo controllo
/// «Riprendi» aprirebbe una schermata che esplode. Quando il collegamento
/// arriva, questo ramo smette da solo di scattare.
void _resumeWorkout(
  BuildContext context,
  WidgetRef ref,
  OpenWorkoutSession session,
) {
  if (!_liveWorkoutIsWired(ref)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'La sessione dal vivo non è ancora attiva su questa '
          'installazione. La sessione aperta resta dov\'è.',
        ),
      ),
    );
    return;
  }
  GoRouter.of(context).push('/workout/${session.id}');
}

/// L'allenamento si avvia dalla scheda, in Palestra: è l'unico posto che
/// oggi sa comporre una sessione. Da qui si arriva con un tocco.
void _openGym(BuildContext context) => GoRouter.of(context).go('/gym');

bool _liveWorkoutIsWired(WidgetRef ref) {
  try {
    ref.read(liveWorkoutRepositoryProvider);
    return true;
  } on Object {
    return false;
  }
}

/// «Cosa mangio adesso»: il suggeritore per macro rimanenti, promosso dalla
/// scheda Ricette alla schermata Oggi.
///
/// Sparisce quando il budget del giorno è chiuso: proporre da mangiare a chi
/// è già oltre il riferimento non aiuta nessuno.
class _TodayRecipesSection extends ConsumerWidget {
  const _TodayRecipesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = ref.watch(remainingMacrosProvider);
    if (remaining.calories <= 0) {
      return const SizedBox.shrink();
    }
    final suggestions = ref.watch(recipeSuggestionsProvider);
    if (suggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: TodayRecipesCard(
        remaining: remaining,
        suggestions: suggestions,
        // `go` e non `push`: la ricetta vive nella voce «Cibo», e la barra
        // in basso deve raccontare la verità su dove si è finiti.
        onOpenRecipe: (id) => GoRouter.of(context).go('/recipes/$id'),
        onOpenAll: () => GoRouter.of(context).go('/recipes'),
      ),
    );
  }
}

/// Punto d'ingresso della foto pasto: azione sotto ogni pasto e stato
/// del job in corso. Attiva solo con Supabase configurato; senza sessione
/// invita ad accedere in Progressi → Sincronizzazione (mai un crash).
class _PhotoMealSection extends ConsumerWidget {
  const _PhotoMealSection({required this.mealType, required this.day});

  final MealType mealType;
  final DateTime day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured = ref.watch(appConfigProvider).hasSupabaseConfiguration;
    final jobs = ref
        .watch(photoMealJobsProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => const <PhotoMealJob>[],
        );
    final mealJobs = [
      for (final job in jobs)
        if (job.mealType == mealType && DiaryDay.isSameDay(job.day, day)) job,
    ];

    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            key: Key('photo_meal_button_${mealType.storageValue}'),
            onPressed: configured ? () => _capturePhoto(context, ref) : null,
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: const Text('Fotografa il pasto'),
          ),
          for (final job in mealJobs)
            _PhotoJobStatusRow(
              key: Key('photo_job_status_${job.id}'),
              job: job,
            ),
        ],
      ),
    );
  }

  // Flusso condiviso col menu smart del FAB (guard, sorgente, snackbar):
  // qui il pasto arriva dal contesto, lì lo sceglie prima Marco.
  Future<void> _capturePhoto(BuildContext context, WidgetRef ref) =>
      startPhotoMealCapture(
        context: context,
        ref: ref,
        mealType: mealType,
        day: day,
      );
}

class _PhotoJobStatusRow extends ConsumerWidget {
  const _PhotoJobStatusRow({required this.job, super.key});

  final PhotoMealJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reviewReady = job.status == PhotoMealJobStatus.needsReview;
    // Totale stimato della proposta (per100g × grammi suggeriti, sempre
    // calcolato dall'app): null per i risultati vecchi senza per100g,
    // che mostrano l'etichetta di stato come oggi.
    final estimatedCalories = reviewReady
        ? estimatedCaloriesFromRaw(job.analysisResult)
        : null;
    return InkWell(
      key: Key('photo_job_open_${job.id}'),
      // La riga «proposta pronta da rivedere» deve portare alla revisione:
      // la snackbar dura 8 secondi e non può essere l'unico ingresso.
      onTap: reviewReady
          ? () => GoRouter.of(context).push('/photo-review/${job.id}')
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 4),
        child: Row(
          children: [
            if (job.inProgress)
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                job.status == PhotoMealJobStatus.failed
                    ? Icons.error_outline_rounded
                    : Icons.fact_check_outlined,
                size: 16,
                color: AppPalette.mutedInk,
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                key: Key('photo_job_label_${job.id}'),
                estimatedCalories == null
                    ? 'Foto: ${job.status.label.toLowerCase()}'
                    : 'Foto: ≈ ${estimatedCalories.round()} kcal da rivedere',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
              ),
            ),
            if (reviewReady)
              const Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: AppPalette.mutedInk,
              ),
            if (job.inProgress)
              IconButton(
                key: Key('photo_job_refresh_${job.id}'),
                tooltip: 'Aggiorna lo stato',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () =>
                    ref.read(photoMealJobsProvider.notifier).refresh(),
              ),
          ],
        ),
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

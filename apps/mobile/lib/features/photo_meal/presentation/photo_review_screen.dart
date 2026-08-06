import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/theme/app_breakpoints.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/diary_number_field.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_repository.dart';
import 'package:kal_tracker/features/photo_meal/presentation/meal_analysis_result.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_meal_job.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_local_store.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_providers.dart';

/// Revisione delle proposte AI per una foto pasto (rotta /photo-review/:id).
/// Regola 1: NIENTE entra nel diario senza un tocco esplicito di Marco.
/// Ogni voce è modificabile (nome, grammi, valori per 100 g) e
/// deselezionabile; l'anteprima usa sempre NutritionCalculator. Il modello
/// non fornisce MAI i totali: quando propone i valori per 100 g
/// (`per100g`, worker nuovo) i campi arrivano precompilati con le stime e
/// le kcal mostrate restano calcolate dall'app («≈ … · stima da foto»);
/// senza `per100g` (risultato vecchio già nel database) i valori per
/// 100 g li completa Marco prima della conferma, come oggi.
class PhotoReviewScreen extends ConsumerStatefulWidget {
  const PhotoReviewScreen({required this.jobId, super.key});

  final String jobId;

  @override
  ConsumerState<PhotoReviewScreen> createState() => _PhotoReviewScreenState();
}

class _PhotoReviewScreenState extends ConsumerState<PhotoReviewScreen> {
  final List<_ProposalRow> _rows = [];
  String? _rowsJobId;
  MealType _mealType = MealType.lunch;
  bool _busy = false;
  String? _closedMessage;

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final jobAsync = ref.watch(photoReviewJobProvider(widget.jobId));
    return Scaffold(
      appBar: AppBar(title: const Text('Rivedi la proposta')),
      body: _closedMessage != null
          ? _InfoBody(
              icon: Icons.check_circle_outline_rounded,
              title: 'Fatto',
              message: _closedMessage!,
            )
          : jobAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) => _InfoBody(
                icon: Icons.cloud_off_rounded,
                title: 'Non riesco a leggere l’analisi',
                message: '$error',
                actions: [_refreshButton()],
              ),
              data: (job) => job == null
                  ? const _InfoBody(
                      icon: Icons.search_off_rounded,
                      title: 'Analisi non trovata',
                      message:
                          'Questo job non esiste più oppure non è tuo. '
                          'Puoi comunque aggiungere il pasto a mano.',
                    )
                  : _bodyFor(job),
            ),
    );
  }

  Widget _bodyFor(PhotoMealJob job) {
    if (job.isReadyForReview) {
      _ensureRows(job);
      return _reviewBody(job);
    }
    if (job.isActive) {
      final stuck = job.attemptCount >= 10;
      return _InfoBody(
        icon: Icons.hourglass_top_rounded,
        title: stuck ? 'Analisi ferma' : 'Analisi in attesa',
        message: stuck
            ? 'Dopo ${job.attemptCount} tentativi l’analisi non è arrivata: '
                  'meglio aggiungere il pasto a mano.'
            : 'Il Mac analizza la foto appena è acceso e in rete. '
                  'Puoi aspettare qui oppure aggiungere il pasto a mano: '
                  'la coda non blocca mai il diario.',
        details: [
          if (job.attemptCount > 0) 'Tentativi: ${job.attemptCount} di 10.',
          if (job.userNote?.isNotEmpty ?? false) 'Nota: ${job.userNote}',
        ],
        actions: [
          _refreshButton(),
          _manualAddButton(),
          if (stuck) _discardButton(job),
        ],
      );
    }
    return switch (job.status) {
      PhotoMealJobStatus.needsReview => _InfoBody(
        icon: Icons.report_gmailerrorred_rounded,
        title: 'Risultato non leggibile',
        message:
            'La proposta del modello non rispetta il contratto e non può '
            'essere mostrata. Aggiungi il pasto a mano.',
        details: [if (job.resultError != null) 'Dettaglio: ${job.resultError}'],
        actions: [_manualAddButton(), _discardButton(job)],
      ),
      PhotoMealJobStatus.failed => _InfoBody(
        icon: Icons.error_outline_rounded,
        title: 'Analisi non riuscita',
        message: 'Il worker ha rinunciato dopo ${job.attemptCount} tentativi.',
        details: ['Codice: ${job.errorCode ?? 'sconosciuto'}'],
        actions: [_manualAddButton(), _discardButton(job)],
      ),
      PhotoMealJobStatus.confirmed => _InfoBody(
        icon: Icons.check_circle_outline_rounded,
        title: 'Già confermata',
        message: 'Questa proposta risulta già gestita.',
        actions: [_discardButton(job)],
      ),
      _ => _InfoBody(
        icon: Icons.help_outline_rounded,
        title: 'Analisi chiusa',
        message:
            'Stato: ${job.status.storageValue}. Nel diario non è '
            'entrato nulla: puoi aggiungere il pasto a mano.',
        actions: [_manualAddButton(), _discardButton(job)],
      ),
    };
  }

  void _ensureRows(PhotoMealJob job) {
    if (_rowsJobId == job.id) {
      return;
    }
    for (final row in _rows) {
      row.dispose();
    }
    _rows
      ..clear()
      ..addAll(job.result!.foods.map(_ProposalRow.new));
    _rowsJobId = job.id;
    _mealType = MealType.fromStorage(job.requestedMealType ?? 'lunch');
  }

  Widget _reviewBody(PhotoMealJob job) {
    final result = job.result!;
    // Un modulo da correggere voce per voce: colonna sola, centrata. Le
    // proposte si controllano in ordine, e il totale in cima deve restare
    // sotto l'occhio mentre si scende — affiancare due voci su schermo largo
    // farebbe perdere il segno proprio dove serve attenzione, e i campi dei
    // valori per 100 g non guadagnano nulla a essere più larghi.
    return AdaptiveLayout(
      builder: (context, size) => AdaptiveContent(
        child: SingleChildScrollView(
          key: const Key('photo_review_body'),
          padding: AppBreakpoints.pagePadding(size),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AnalysisHeader(result: result, userNote: job.userNote),
              const SizedBox(height: 16),
              DropdownButtonFormField<MealType>(
                key: const Key('review_meal_type'),
                initialValue: _mealType,
                decoration: const InputDecoration(labelText: 'Pasto'),
                items: [
                  for (final type in MealType.values)
                    DropdownMenuItem(value: type, child: Text(type.label)),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _mealType = value!),
              ),
              const SizedBox(height: 12),
              // Il totale sta IN ALTO e si ricalcola a ogni modifica: con le
              // stime da foto è la prima cosa che Marco vede.
              _TotalsCard(label: _totalsLabel()),
              const SizedBox(height: 12),
              for (final (index, row) in _rows.indexed) ...[
                _proposalCard(index, row),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('confirm_review_button'),
                onPressed: _busy || !_rows.any((row) => row.selected)
                    ? null
                    : () => _confirm(job),
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_busy ? 'Salvataggio…' : 'Aggiungi al diario'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('discard_review_button'),
                onPressed: _busy ? null : () => _discard(job),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Scarta tutto'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _proposalCard(int index, _ProposalRow row) {
    final food = row.food;
    final preview = row.preview;
    final enabled = row.selected && !_busy;
    return Card(
      key: Key('food_card_$index'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  key: Key('food_selected_$index'),
                  value: row.selected,
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => row.selected = value ?? false),
                ),
                Expanded(
                  child: TextFormField(
                    key: Key('food_name_$index'),
                    controller: row.name,
                    enabled: enabled,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(labelText: 'Alimento'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('Fiducia ${(food.confidence * 100).round()}%'),
                ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(food.preparationLabel),
                ),
                for (final (altIndex, alternative) in food.alternatives.indexed)
                  ActionChip(
                    key: Key('food_alternative_${index}_$altIndex'),
                    visualDensity: VisualDensity.compact,
                    label: Text('Forse: $alternative'),
                    onPressed: enabled
                        ? () => setState(() => row.name.text = alternative)
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            DiaryNumberField(
              key: Key('food_grams_$index'),
              controller: row.grams,
              label: 'Quantità (g)',
              mustBePositive: true,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 4),
            Text(
              'Stima del modello: '
              '${editableDiaryNumber(food.minimumGrams)}–'
              '${editableDiaryNumber(food.maximumGrams)} g '
              '(proposti ${editableDiaryNumber(food.suggestedGrams)} g).',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DiaryNumberField(
                    key: Key('food_calories_$index'),
                    controller: row.calories,
                    label: 'Calorie per 100 g (kcal)',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DiaryNumberField(
                    key: Key('food_protein_$index'),
                    controller: row.protein,
                    label: 'Proteine per 100 g',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DiaryNumberField(
                    key: Key('food_carbs_$index'),
                    controller: row.carbs,
                    label: 'Carboidrati per 100 g',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DiaryNumberField(
                    key: Key('food_fat_$index'),
                    controller: row.fat,
                    label: 'Grassi per 100 g',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            if (food.hiddenIngredients.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Possibili ingredienti nascosti: '
                '${food.hiddenIngredients.join(', ')}.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
              ),
            ],
            if (food.uncertainty.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                food.uncertainty,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
              ),
            ],
            const SizedBox(height: 10),
            // Con le stime da foto le kcal (sempre calcolate dall'app,
            // mai dal modello) si presentano come stime da verificare.
            Text(
              key: Key('food_preview_$index'),
              !row.selected
                  ? 'Esclusa dal diario'
                  : preview == null
                  ? '— kcal'
                  : '${row.hasPhotoEstimate ? '≈ ' : ''}'
                        '${preview.calories.round()} kcal · '
                        'P ${preview.protein.toStringAsFixed(1)} · '
                        'C ${preview.carbs.toStringAsFixed(1)} · '
                        'G ${preview.fat.toStringAsFixed(1)}'
                        '${row.hasPhotoEstimate ? ' · stima da foto' : ''}',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: row.selected
                    ? AppPalette.forestDark
                    : AppPalette.mutedInk,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _totalsLabel() {
    final selected = [
      for (final row in _rows)
        if (row.selected) row,
    ];
    if (selected.isEmpty) {
      return 'Nessuna voce selezionata.';
    }
    var totals = const Nutrients.zero();
    var estimated = false;
    for (final row in selected) {
      final preview = row.preview;
      if (preview == null) {
        return 'Totale selezionato: — kcal (completa i valori).';
      }
      estimated = estimated || row.hasPhotoEstimate;
      totals = totals + preview;
    }
    // Il «≈» segnala che almeno una voce parte dalle stime della foto.
    return 'Totale selezionato: ${estimated ? '≈ ' : ''}'
        '${totals.calories.round()} kcal · '
        'P ${totals.protein.toStringAsFixed(1)} · '
        'C ${totals.carbs.toStringAsFixed(1)} · '
        'G ${totals.fat.toStringAsFixed(1)}';
  }

  Future<void> _confirm(PhotoMealJob job) async {
    final selected = [
      for (final (index, row) in _rows.indexed)
        if (row.selected) (index, row),
    ];
    if (selected.isEmpty) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final eatenAt = await _resolveEatenAt(job.id);
    final inputs = <ManualFoodInput>[];
    for (final (index, row) in selected) {
      final name = row.name.text.trim();
      final grams = parseDiaryNumber(row.grams.text);
      final calories = parseDiaryNumber(row.calories.text);
      final protein = parseDiaryNumber(row.protein.text);
      final carbs = parseDiaryNumber(row.carbs.text);
      final fat = parseDiaryNumber(row.fat.text);
      final valid =
          name.isNotEmpty &&
          grams != null &&
          grams > 0 &&
          calories != null &&
          calories >= 0 &&
          protein != null &&
          protein >= 0 &&
          carbs != null &&
          carbs >= 0 &&
          fat != null &&
          fat >= 0;
      if (!valid) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Controlla i valori di «${name.isEmpty ? 'voce ${index + 1}' : name}».',
            ),
          ),
        );
        return;
      }
      inputs.add(
        ManualFoodInput(
          foodName: name,
          grams: grams,
          per100g: Nutrients(
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
          ),
          mealType: _mealType,
          eatenAt: eatenAt,
        ),
      );
    }
    setState(() => _busy = true);
    final store = ref.read(photoReviewLocalStoreProvider);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      // PRIMA il registro handled, POI il diario: se il registro non si
      // scrive il diario resta intatto (un nuovo tocco non duplica nulla)
      // e se l'app muore subito dopo la proposta non viene ripresentata
      // come nuova e riconfermabile.
      await store.markHandled(jobId: job.id, outcome: 'confirmed');
      try {
        await ref
            .read(diaryRepositoryProvider)
            .addEntries(profileId: profile.id, inputs: inputs);
      } on Object {
        // Nel diario non è entrato nulla: la proposta torna riconfermabile.
        try {
          await store.unmarkHandled(jobId: job.id);
        } on Object {
          // Meglio una proposta chiusa a vuoto che voci duplicate.
        }
        rethrow;
      }
    } on Object {
      if (mounted) {
        setState(() => _busy = false);
        messenger.showSnackBar(
          const SnackBar(content: Text('Non riesco a salvare nel diario.')),
        );
      }
      return;
    }
    // Diario scritto e registro aggiornato: da qui la conferma è definitiva
    // e nessun intoppo di pulizia deve riabilitare il bottone.
    try {
      await ref
          .read(photoJobsControllerProvider.notifier)
          .closeJobLocally(job, outcome: 'confirmed');
    } on Object {
      // Chiusura best-effort: l'esito è già nel registro handled.
    }
    if (!mounted) {
      return;
    }
    final message =
        '${inputs.length} ${inputs.length == 1 ? 'voce aggiunta' : 'voci aggiunte'} al diario.';
    setState(() => _closedMessage = message);
    messenger.showSnackBar(SnackBar(content: Text(message)));
    await Navigator.of(context).maybePop();
  }

  /// Il giorno di diario per cui la foto era stata scattata vive nel
  /// registro locale dei job (la riga remota non ha una colonna day):
  /// la conferma deve finire in QUEL giorno, come il percorso manuale.
  /// Senza registro (deep link dopo reinstallo) si ricade su adesso.
  Future<DateTime> _resolveEatenAt(String jobId) async {
    try {
      final localJobs = await ref.read(photoMealRepositoryProvider).loadJobs();
      for (final local in localJobs) {
        if (local.id == jobId) {
          final today = ref.read(todayProvider);
          return DiaryDay.isSameDay(local.day, today)
              ? AppTime.nowInRome()
              : DiaryDay.instantFor(local.day);
        }
      }
    } on Object {
      // Registro locale illeggibile: vale il giorno corrente.
    }
    return AppTime.nowInRome();
  }

  Future<void> _discard(PhotoMealJob job) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('discard_review_dialog'),
        title: const Text('Scarto tutte le proposte?'),
        content: const Text(
          'Nel diario non entra nulla e la foto viene tolta dal cloud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: const Key('confirm_discard_button'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Scarta'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(photoJobsControllerProvider.notifier)
          .closeJobLocally(job, outcome: 'discarded');
      if (!mounted) {
        return;
      }
      const message = 'Proposte scartate: nel diario non è entrato nulla.';
      setState(() => _closedMessage = message);
      messenger.showSnackBar(const SnackBar(content: Text(message)));
      await Navigator.of(context).maybePop();
    } on Object {
      if (mounted) {
        setState(() => _busy = false);
        messenger.showSnackBar(
          const SnackBar(content: Text('Non riesco a scartare le proposte.')),
        );
      }
    }
  }

  Widget _refreshButton() => OutlinedButton.icon(
    key: const Key('refresh_job_button'),
    onPressed: () => ref.invalidate(photoReviewJobProvider(widget.jobId)),
    icon: const Icon(Icons.refresh_rounded),
    label: const Text('Ricarica'),
  );

  Widget _manualAddButton() => FilledButton.icon(
    key: const Key('manual_add_button'),
    onPressed: () => showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const AddManualFoodSheet(),
    ),
    icon: const Icon(Icons.edit_rounded),
    label: const Text('Aggiungi a mano'),
  );

  Widget _discardButton(PhotoMealJob job) => OutlinedButton.icon(
    key: const Key('discard_review_button'),
    onPressed: _busy ? null : () => _discard(job),
    icon: const Icon(Icons.delete_outline_rounded),
    label: const Text('Scarta'),
  );
}

/// Una proposta del modello con i campi modificabili da Marco.
class _ProposalRow {
  _ProposalRow(this.food)
    : name = TextEditingController(text: food.name),
      grams = TextEditingController(
        text: editableDiaryNumber(food.suggestedGrams),
      ),
      // Con `per100g` i campi partono dalle stime del modello (sempre
      // modificabili); senza (risultato vecchio già nel database) restano
      // gli «0» da compilare a mano, come oggi.
      calories = TextEditingController(
        text: _initialPer100g(food.per100g?.energyKcal),
      ),
      protein = TextEditingController(
        text: _initialPer100g(food.per100g?.proteinG),
      ),
      carbs = TextEditingController(
        text: _initialPer100g(food.per100g?.carbsG),
      ),
      fat = TextEditingController(text: _initialPer100g(food.per100g?.fatG));

  static String _initialPer100g(double? value) =>
      value == null ? '0' : editableDiaryNumber(value);

  final MealAnalysisFood food;
  final TextEditingController name;
  final TextEditingController grams;
  final TextEditingController calories;
  final TextEditingController protein;
  final TextEditingController carbs;
  final TextEditingController fat;
  bool selected = true;

  /// I valori per 100 g sono partiti dalle stime della foto: l'anteprima
  /// va presentata come stima da verificare.
  bool get hasPhotoEstimate => food.per100g != null;

  /// Anteprima nutrizionale: SEMPRE via NutritionCalculator.scale.
  Nutrients? get preview {
    final gramsValue = parseDiaryNumber(grams.text);
    final caloriesValue = parseDiaryNumber(calories.text);
    final proteinValue = parseDiaryNumber(protein.text);
    final carbsValue = parseDiaryNumber(carbs.text);
    final fatValue = parseDiaryNumber(fat.text);
    if (gramsValue == null ||
        caloriesValue == null ||
        proteinValue == null ||
        carbsValue == null ||
        fatValue == null) {
      return null;
    }
    try {
      return NutritionCalculator.scale(
        per100g: Nutrients(
          calories: caloriesValue,
          protein: proteinValue,
          carbs: carbsValue,
          fat: fatValue,
        ),
        grams: gramsValue,
      );
    } on FormatException {
      return null;
    }
  }

  void dispose() {
    name.dispose();
    grams.dispose();
    calories.dispose();
    protein.dispose();
    carbs.dispose();
    fat.dispose();
  }
}

class _AnalysisHeader extends StatelessWidget {
  const _AnalysisHeader({required this.result, this.userNote});

  final MealAnalysisResult result;
  final String? userNote;

  @override
  Widget build(BuildContext context) {
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
              'Proposta del modello · fiducia '
              '${(result.overallConfidence * 100).round()}%',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppPalette.forestDark,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Controlla, correggi e scegli cosa salvare: senza la tua '
              'conferma non entra nulla nel diario.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (result.notes.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                result.notes,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
              ),
            ],
            for (final question in result.questions) ...[
              const SizedBox(height: 4),
              Text(
                '• $question',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
              ),
            ],
            if (userNote?.isNotEmpty ?? false) ...[
              const SizedBox(height: 6),
              Text(
                'La tua nota: $userNote',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.mint,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Text(
          key: const Key('review_totals'),
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w900,
            color: AppPalette.forestDark,
          ),
        ),
      ),
    );
  }
}

class _InfoBody extends StatelessWidget {
  const _InfoBody({
    required this.icon,
    required this.title,
    required this.message,
    this.details = const [],
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String message;
  final List<String> details;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    // Un messaggio con due pulsanti: centrato in verticale, ma anche largo
    // quanto una riga leggibile — su tablet «Il Mac analizza la foto appena è
    // acceso…» su una riga sola da un bordo all'altro non si legge.
    return AdaptiveContent(
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 44, color: AppPalette.forestDark),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            for (final detail in details) ...[
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

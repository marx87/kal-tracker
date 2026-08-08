import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/health/data/health_data_service.dart';
import 'package:kal_tracker/features/health/domain/health_data_gateway.dart';
import 'package:kal_tracker/features/health/presentation/health_providers.dart';
import 'package:kal_tracker/features/health/presentation/health_ui_providers.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';

class HealthScreen extends ConsumerStatefulWidget {
  const HealthScreen({super.key});

  static const routeName = 'health';

  @override
  ConsumerState<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends ConsumerState<HealthScreen> {
  _HealthAction? _busyAction;
  String? _outcome;

  bool get _isBusy => _busyAction != null;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(healthGatewayStatusProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Health360')),
      body: AdaptiveLayout(
        builder: (context, size) => AdaptiveContent(
          child: ListView(
            key: const Key('health_screen_list'),
            padding: AppBreakpoints.pagePadding(size),
            children: [
              status.when(
                data: (value) => _buildAvailableContent(value),
                loading: () => const _LoadingStatusCard(),
                error: (error, stackTrace) => _StatusErrorCard(
                  onRetry: () => ref.invalidate(healthGatewayStatusProvider),
                ),
              ),
              const SizedBox(height: 14),
              const _HuaweiPathCard(),
              const SizedBox(height: 14),
              const _CalorieBudgetCard(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvailableContent(HealthGatewayStatus status) {
    final summaries = ref.watch(recentHealthSummariesProvider);
    final readCapabilities = _readCapabilities.intersection(
      status.capabilities,
    );
    final canImport =
        readCapabilities.isNotEmpty && readCapabilities.every(status.isGranted);
    final canExport = status.isGranted(HealthCapability.writeWorkout);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ConnectionCard(
          status: status,
          busy: _busyAction == _HealthAction.connect,
          onConnect: _isBusy ? null : () => _connect(status),
        ),
        if (_outcome case final message?) ...[
          const SizedBox(height: 12),
          _OutcomeMessage(message: message),
        ],
        const SizedBox(height: 14),
        _CapabilitiesCard(status: status),
        const SizedBox(height: 14),
        SectionCard(
          title: 'Ultimi 7 giorni sul dispositivo',
          subtitle: 'Il riepilogo legge solo i dati già importati in Coach360.',
          icon: Icons.monitor_heart_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              summaries.when(
                data: (items) => _LocalSummary(
                  summaries: _forCurrentSource(items, status.source),
                ),
                loading: () => const LinearProgressIndicator(
                  key: Key('health_summaries_loading'),
                ),
                error: (error, stackTrace) => _InlineError(
                  message: 'Non riesco a leggere il riepilogo locale.',
                  onRetry: () => ref.invalidate(recentHealthSummariesProvider),
                ),
              ),
              const SizedBox(height: 16),
              _HealthActionButton(
                key: const Key('health_import_button'),
                icon: Icons.download_rounded,
                label: 'Importa ultimi 7 giorni',
                busy: _busyAction == _HealthAction.import,
                onPressed: !_isBusy && canImport ? _importLastWeek : null,
              ),
              if (!canImport) ...[
                const SizedBox(height: 8),
                const Text(
                  'Connetti prima la sorgente e autorizza almeno un dato da '
                  'leggere. Questo pulsante non chiede mai permessi da solo.',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        SectionCard(
          title: 'Allenamenti Coach360',
          subtitle: canExport
              ? 'Invia fino a 20 sessioni recenti. L\'ID evita i duplicati.'
              : 'L\'esportazione compare dopo il permesso di scrittura.',
          icon: Icons.fitness_center_rounded,
          child: canExport
              ? _HealthActionButton(
                  key: const Key('health_export_workouts_button'),
                  icon: Icons.upload_rounded,
                  label: 'Esporta allenamenti recenti',
                  busy: _busyAction == _HealthAction.export,
                  tonal: true,
                  onPressed: _isBusy ? null : _exportRecentWorkouts,
                )
              : const Text(
                  'Tocca «Connetti» e scegli se consentire a Coach360 di '
                  'scrivere gli allenamenti nella sorgente salute.',
                ),
        ),
      ],
    );
  }

  Future<void> _connect(HealthGatewayStatus current) async {
    final requested = current.capabilities;
    if (requested.isEmpty) {
      _showOutcome(
        current.detail ??
            'Il collegamento salute non è disponibile su questa installazione.',
      );
      return;
    }
    setState(() => _busyAction = _HealthAction.connect);
    try {
      final updated = await ref
          .read(healthDataServiceProvider)
          .requestAuthorization(requested);
      if (!mounted) return;
      final granted = requested.where(updated.isGranted).length;
      _showOutcome(
        granted == requested.length
            ? 'Health360 connesso: autorizzazioni aggiornate.'
            : granted == 0
            ? 'Nessuna autorizzazione concessa. Puoi riprovare quando vuoi.'
            : '$granted autorizzazioni su ${requested.length} concesse.',
      );
      ref.invalidate(healthGatewayStatusProvider);
    } on Object {
      if (mounted) {
        _showOutcome(
          'Non riesco ad aprire le autorizzazioni. Riprova dal telefono.',
        );
      }
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _importLastWeek() async {
    setState(() => _busyAction = _HealthAction.import);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final throughDay = healthCalendarDay(ref.read(todayProvider));
      final result = await ref
          .read(healthDataServiceProvider)
          .importDailySummaries(
            profileId: profile.id,
            fromDay: throughDay.subtract(const Duration(days: 6)),
            throughDay: throughDay,
          );
      if (!mounted) return;
      final message = switch (result.state) {
        HealthImportState.imported =>
          result.imported == 1
              ? 'Importato 1 riepilogo giornaliero.'
              : 'Importati ${result.imported} riepiloghi giornalieri.',
        HealthImportState.noData =>
          'Nessun nuovo dato disponibile negli ultimi 7 giorni.',
        HealthImportState.permissionRequired =>
          'Autorizzazione mancante: usa prima «Connetti».',
        HealthImportState.unavailable =>
          'La sorgente non rende disponibili questi dati.',
      };
      _showOutcome(message);
      ref.invalidate(recentHealthSummariesProvider);
      ref.invalidate(healthGatewayStatusProvider);
    } on Object {
      if (mounted) {
        _showOutcome(
          'Importazione non riuscita. I dati già salvati restano al sicuro.',
        );
      }
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _exportRecentWorkouts() async {
    setState(() => _busyAction = _HealthAction.export);
    try {
      final workouts =
          (await ref
                  .read(liveWorkoutRepositoryProvider)
                  .recentClosedWorkouts(limit: 20))
              .where((workout) => workout.endedAt != null)
              .toList(growable: false);
      if (!mounted) return;
      if (workouts.isEmpty) {
        _showOutcome('Nessun allenamento recente da esportare.');
        return;
      }

      var written = 0;
      var alreadyPresent = 0;
      var failed = 0;
      var permissionLost = false;
      for (final workout in workouts) {
        final result = await ref
            .read(healthDataServiceProvider)
            .writeWorkout(_healthRecord(workout));
        switch (result.state) {
          case HealthWorkoutWriteState.written:
            written++;
          case HealthWorkoutWriteState.alreadyPresent:
            alreadyPresent++;
          case HealthWorkoutWriteState.permissionRequired:
          case HealthWorkoutWriteState.unsupported:
            permissionLost = true;
          case HealthWorkoutWriteState.failed:
            failed++;
        }
        if (permissionLost) break;
      }
      if (!mounted) return;
      if (permissionLost) {
        _showOutcome(
          'Il permesso di esportazione non è più disponibile. Tocca '
          '«Connetti» per rivederlo.',
        );
        ref.invalidate(healthGatewayStatusProvider);
        return;
      }
      _showOutcome(
        _workoutExportMessage(
          written: written,
          alreadyPresent: alreadyPresent,
          failed: failed,
        ),
      );
    } on Object {
      if (mounted) {
        _showOutcome(
          'Esportazione non riuscita. Gli allenamenti restano in Coach360.',
        );
      }
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  void _showOutcome(String message) {
    if (!mounted) return;
    setState(() => _outcome = message);
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

const _readCapabilities = {
  HealthCapability.readSteps,
  HealthCapability.readSleep,
  HealthCapability.readRestingHeartRate,
};

enum _HealthAction { connect, import, export }

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.status,
    required this.busy,
    required this.onConnect,
  });

  final HealthGatewayStatus status;
  final bool busy;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final connected = status.capabilities.any(status.isGranted);
    final level = status.capabilities.isEmpty
        ? AppStatusLevel.warning
        : connected
        ? AppStatusLevel.good
        : AppStatusLevel.warning;
    final stateLabel = status.capabilities.isEmpty
        ? 'Non disponibile'
        : connected
        ? 'Connesso'
        : 'Da connettere';

    return SectionCard(
      title: 'La tua sorgente salute',
      subtitle: 'Permessi sempre sotto il tuo controllo.',
      icon: Icons.favorite_rounded,
      background: Theme.of(context).colorScheme.primaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip(level: level, label: stateLabel),
              Text(
                'Sorgente: ${_sourceLabel(status.source)}',
                key: const Key('health_source_label'),
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          if (status.detail case final detail?) ...[
            const SizedBox(height: 10),
            Text(detail),
          ],
          const SizedBox(height: 16),
          _HealthActionButton(
            key: const Key('health_connect_button'),
            icon: Icons.link_rounded,
            label: connected ? 'Aggiorna autorizzazioni' : 'Connetti',
            busy: busy,
            onPressed: onConnect,
          ),
        ],
      ),
    );
  }
}

class _CapabilitiesCard extends StatelessWidget {
  const _CapabilitiesCard({required this.status});

  final HealthGatewayStatus status;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Dati e autorizzazioni',
      subtitle: 'Disponibilità e permesso sono due cose diverse.',
      icon: Icons.admin_panel_settings_outlined,
      child: Column(
        children: [
          for (
            var index = 0;
            index < HealthCapability.values.length;
            index++
          ) ...[
            _CapabilityRow(
              capability: HealthCapability.values[index],
              supported: status.supports(HealthCapability.values[index]),
              permission:
                  status.permissions[HealthCapability.values[index]] ??
                  HealthPermissionState.notRequested,
            ),
            if (index != HealthCapability.values.length - 1)
              const Divider(height: 24),
          ],
        ],
      ),
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.capability,
    required this.supported,
    required this.permission,
  });

  final HealthCapability capability;
  final bool supported;
  final HealthPermissionState permission;

  @override
  Widget build(BuildContext context) {
    final metadata = switch (capability) {
      HealthCapability.readSteps => (
        icon: Icons.directions_walk_rounded,
        title: 'Passi',
        detail: 'Totale giornaliero',
      ),
      HealthCapability.readSleep => (
        icon: Icons.bedtime_outlined,
        title: 'Sonno',
        detail: 'Minuti dormiti',
      ),
      HealthCapability.readRestingHeartRate => (
        icon: Icons.monitor_heart_outlined,
        title: 'Frequenza a riposo',
        detail: 'Battiti al minuto',
      ),
      HealthCapability.writeWorkout => (
        icon: Icons.fitness_center_rounded,
        title: 'Esporta allenamenti',
        detail: 'Sessioni concluse da Coach360',
      ),
    };
    final view = _permissionView(supported, permission);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(metadata.icon, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                metadata.title,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(metadata.detail),
              const SizedBox(height: 7),
              StatusChip(
                key: Key('health_capability_${capability.name}'),
                level: view.level,
                label: view.label,
                compact: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LocalSummary extends StatelessWidget {
  const _LocalSummary({required this.summaries});

  final List<HealthDailySummary> summaries;

  @override
  Widget build(BuildContext context) {
    if (summaries.isEmpty) {
      return const Text(
        'Non ci sono ancora dati locali. Dopo aver connesso la sorgente, '
        'avvia tu la prima importazione.',
        key: Key('health_local_summary_empty'),
      );
    }
    final overview = _HealthOverview.from(summaries);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${summaries.length} ${summaries.length == 1 ? 'giorno' : 'giorni'} '
          'con dati salvati',
          key: const Key('health_summary_days'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final tiles = [
              _MetricTile(
                key: const Key('health_steps_summary'),
                icon: Icons.directions_walk_rounded,
                value: overview.steps,
                label: 'passi totali',
              ),
              _MetricTile(
                key: const Key('health_sleep_summary'),
                icon: Icons.bedtime_outlined,
                value: overview.sleep,
                label: 'sonno medio',
              ),
              _MetricTile(
                key: const Key('health_resting_hr_summary'),
                icon: Icons.favorite_outline_rounded,
                value: overview.restingHeartRate,
                label: 'ultimo valore a riposo',
              ),
            ];
            if (constraints.maxWidth < 520) {
              return Column(
                children: [
                  for (var index = 0; index < tiles.length; index++) ...[
                    tiles[index],
                    if (index != tiles.length - 1) const SizedBox(height: 8),
                  ],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < tiles.length; index++) ...[
                  Expanded(child: tiles[index]),
                  if (index != tiles.length - 1) const SizedBox(width: 8),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.value,
    required this.label,
    super.key,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(label, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthActionButton extends StatelessWidget {
  const _HealthActionButton({
    required this.icon,
    required this.label,
    required this.busy,
    required this.onPressed,
    this.tonal = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (busy)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, size: 20),
          const SizedBox(width: 9),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    return SizedBox(
      width: double.infinity,
      child: tonal
          ? FilledButton.tonal(onPressed: onPressed, child: content)
          : FilledButton(onPressed: onPressed, child: content),
    );
  }
}

class _OutcomeMessage extends StatelessWidget {
  const _OutcomeMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final accents = AppAccents.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('health_outcome_message'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: accents.infoSurface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: accents.info),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _HuaweiPathCard extends StatelessWidget {
  const _HuaweiPathCard();

  @override
  Widget build(BuildContext context) {
    return const SectionCard(
      title: 'Huawei: il percorso reale dei dati',
      icon: Icons.watch_outlined,
      child: Text(
        'Coach360 non si collega direttamente all\'orologio. Quando il tuo '
        'modello, la regione e Huawei Health lo consentono, su Android il '
        'percorso è Huawei Health → Health Connect; su iPhone è Huawei '
        'Health → Apple Salute (HealthKit). Se Huawei non condivide un dato '
        'con quel sistema, Coach360 non può inventarlo né promettere di '
        'importarlo.',
      ),
    );
  }
}

class _CalorieBudgetCard extends StatelessWidget {
  const _CalorieBudgetCard();

  @override
  Widget build(BuildContext context) {
    final accents = AppAccents.of(context);
    return Card(
      key: const Key('health_calorie_budget_note'),
      color: accents.warningSurface,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.restaurant_rounded, color: accents.warning),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Le calorie dell\'orologio non aumentano il budget',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Descrivono l\'attività, non sono calorie da mangiare in '
                    'più. Il budget alimentare resta quello del piano, così '
                    'evitiamo di contare due volte lo stesso movimento.',
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

class _LoadingStatusCard extends StatelessWidget {
  const _LoadingStatusCard();

  @override
  Widget build(BuildContext context) {
    return const SectionCard(
      title: 'Controllo la sorgente salute',
      icon: Icons.favorite_outline_rounded,
      child: LinearProgressIndicator(key: Key('health_status_loading')),
    );
  }
}

class _StatusErrorCard extends StatelessWidget {
  const _StatusErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Sorgente non leggibile',
      icon: Icons.link_off_rounded,
      child: _InlineError(
        message: 'Non riesco a verificare disponibilità e permessi.',
        onRetry: onRetry,
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(message),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: onRetry, child: const Text('Riprova')),
      ],
    );
  }
}

({AppStatusLevel level, String label}) _permissionView(
  bool supported,
  HealthPermissionState state,
) {
  if (!supported || state == HealthPermissionState.unavailable) {
    return (level: AppStatusLevel.warning, label: 'Non supportato');
  }
  return switch (state) {
    HealthPermissionState.granted => (
      level: AppStatusLevel.good,
      label: 'Autorizzato',
    ),
    HealthPermissionState.notRequested => (
      level: AppStatusLevel.warning,
      label: 'Da autorizzare',
    ),
    HealthPermissionState.denied => (
      level: AppStatusLevel.warning,
      label: 'Negato',
    ),
    HealthPermissionState.restricted => (
      level: AppStatusLevel.critical,
      label: 'Limitato dal dispositivo',
    ),
    HealthPermissionState.unavailable => (
      level: AppStatusLevel.warning,
      label: 'Non supportato',
    ),
  };
}

List<HealthDailySummary> _forCurrentSource(
  List<HealthDailySummary> summaries,
  String source,
) {
  final current = summaries
      .where((summary) => summary.source == source)
      .toList(growable: false);
  return current.isEmpty ? summaries : current;
}

class _HealthOverview {
  const _HealthOverview({
    required this.steps,
    required this.sleep,
    required this.restingHeartRate,
  });

  factory _HealthOverview.from(List<HealthDailySummary> summaries) {
    final steps = summaries
        .map((summary) => summary.steps)
        .whereType<int>()
        .toList();
    final sleep = summaries
        .map((summary) => summary.sleepMinutes)
        .whereType<int>()
        .toList();
    final resting =
        summaries.where((summary) => summary.restingHeartRate != null).toList()
          ..sort((a, b) => a.day.compareTo(b.day));
    final totalSteps = steps.fold<int>(0, (total, value) => total + value);
    final averageSleep = sleep.isEmpty
        ? null
        : (sleep.fold<int>(0, (total, value) => total + value) / sleep.length)
              .round();
    final latestResting = resting.isEmpty
        ? null
        : resting.last.restingHeartRate;
    final number = NumberFormat.decimalPattern('it');

    return _HealthOverview(
      steps: steps.isEmpty ? '—' : number.format(totalSteps),
      sleep: averageSleep == null ? '—' : _sleepLabel(averageSleep),
      restingHeartRate: latestResting == null ? '—' : '$latestResting bpm',
    );
  }

  final String steps;
  final String sleep;
  final String restingHeartRate;
}

String _sourceLabel(String source) {
  final normalized = source.trim().toLowerCase().replaceAll('-', '_');
  if (normalized.contains('health_connect')) return 'Health Connect';
  if (normalized.contains('healthkit') ||
      normalized.contains('apple_health') ||
      normalized.contains('apple salute')) {
    return 'Apple Salute (HealthKit)';
  }
  if (normalized.isEmpty || normalized == 'unavailable') {
    return 'Non disponibile';
  }
  return source;
}

String _sleepLabel(int minutes) {
  final hours = minutes ~/ 60;
  final remaining = minutes.remainder(60);
  if (hours == 0) return '$remaining min';
  if (remaining == 0) return '$hours h';
  return '$hours h $remaining min';
}

HealthWorkoutRecord _healthRecord(Workout workout) {
  final routineName = workout.routineName?.trim();
  return HealthWorkoutRecord(
    id: workout.id,
    title: routineName == null || routineName.isEmpty
        ? 'Allenamento Coach360'
        : routineName,
    startedAt: workout.startedAt,
    endedAt: workout.endedAt!,
    totalKcal: workout.totalKcal,
  );
}

String _workoutExportMessage({
  required int written,
  required int alreadyPresent,
  required int failed,
}) {
  if (written == 0 && alreadyPresent > 0 && failed == 0) {
    return alreadyPresent == 1
        ? 'L\'allenamento recente era già presente.'
        : 'Gli allenamenti recenti erano già presenti.';
  }
  final parts = <String>[];
  if (written > 0) {
    parts.add(
      written == 1
          ? '1 allenamento esportato'
          : '$written allenamenti esportati',
    );
  }
  if (alreadyPresent > 0) {
    parts.add(
      alreadyPresent == 1 ? '1 già presente' : '$alreadyPresent già presenti',
    );
  }
  if (failed > 0) {
    parts.add(failed == 1 ? '1 non riuscito' : '$failed non riusciti');
  }
  return '${parts.join(', ')}.';
}

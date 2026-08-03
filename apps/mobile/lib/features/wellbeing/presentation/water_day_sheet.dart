import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/wellbeing/domain/water_settings.dart';
import 'package:kal_tracker/features/wellbeing/domain/wellbeing_models.dart';
import 'package:kal_tracker/features/wellbeing/presentation/water_palette.dart';
import 'package:kal_tracker/features/wellbeing/presentation/wellbeing_providers.dart';

/// Sheet dell'acqua: storico del giorno, obiettivo modificabile e
/// impostazioni promemoria. Si apre toccando il widget acqua del diario.
class WaterDaySheet extends ConsumerStatefulWidget {
  const WaterDaySheet({required this.dayLabel, super.key});

  /// Etichetta amichevole del giorno mostrato ("Oggi", "Ieri", …).
  final String dayLabel;

  @override
  ConsumerState<WaterDaySheet> createState() => _WaterDaySheetState();
}

class _WaterDaySheetState extends ConsumerState<WaterDaySheet> {
  late final TextEditingController _goal;

  @override
  void initState() {
    super.initState();
    final settings =
        ref.read(waterSettingsProvider).valueOrNull ?? const WaterSettings();
    _goal = TextEditingController(text: '${settings.goalMilliliters}');
  }

  @override
  void dispose() {
    _goal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intake = ref
        .watch(selectedDayWaterProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => const DailyWaterIntake.empty(),
        );
    final settings = ref
        .watch(waterSettingsProvider)
        .maybeWhen(data: (value) => value, orElse: () => const WaterSettings());

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Acqua · ${widget.dayLabel.toLowerCase()}',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('close_water_sheet'),
                  tooltip: 'Chiudi',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              '${intake.totalMilliliters} ml su ${settings.goalMilliliters}: '
              'ogni bicchiere conta.',
              style: const TextStyle(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 16),
            _DayHistory(intake: intake, onDelete: _deleteEntry),
            const SizedBox(height: 18),
            Text('Obiettivo', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    key: const Key('water_goal_field'),
                    controller: _goal,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Obiettivo giornaliero (ml)',
                      helperText: 'Tra 500 e 6000 ml',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  key: const Key('save_water_goal_button'),
                  // Il tema dà ai FilledButton larghezza piena: qui il
                  // pulsante vive in una Row e va tenuto compatto.
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(88, 52),
                  ),
                  onPressed: _saveGoal,
                  child: const Text('Salva'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text('Promemoria', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            const Text(
              'Un messaggio gentile per non dimenticare di bere.',
              style: TextStyle(color: AppPalette.mutedInk),
            ),
            SwitchListTile(
              key: const Key('water_reminders_toggle'),
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Ricordamelo tu',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                settings.remindersEnabled
                    ? 'Ogni ${settings.reminderIntervalHours} '
                          '${settings.reminderIntervalHours == 1 ? 'ora' : 'ore'}, '
                          'dalle ${settings.reminderStartHour}:00 '
                          'alle ${settings.reminderEndHour}:00.'
                    : 'Adesso i promemoria sono spenti.',
                style: const TextStyle(color: AppPalette.mutedInk),
              ),
              activeThumbColor: WaterPalette.deep,
              value: settings.remindersEnabled,
              onChanged: (value) => _toggleReminders(enabled: value),
            ),
            if (settings.remindersEnabled) ...[
              const SizedBox(height: 6),
              const Text(
                'Ogni quanto?',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final interval in WaterSettings.allowedIntervals)
                    ChoiceChip(
                      key: Key('water_interval_$interval'),
                      label: Text(
                        interval == 1 ? 'Ogni ora' : 'Ogni ${interval}h',
                      ),
                      selected: settings.reminderIntervalHours == interval,
                      selectedColor: WaterPalette.soft,
                      onSelected: (_) => _updatePlan(intervalHours: interval),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      key: const Key('water_window_start'),
                      initialValue: settings.reminderStartHour,
                      decoration: const InputDecoration(labelText: 'Dalle'),
                      items: [
                        for (var hour = 5; hour <= 12; hour++)
                          DropdownMenuItem(
                            value: hour,
                            child: Text('$hour:00'),
                          ),
                      ],
                      onChanged: (value) =>
                          value == null ? null : _updatePlan(startHour: value),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      key: const Key('water_window_end'),
                      initialValue: settings.reminderEndHour,
                      decoration: const InputDecoration(labelText: 'Alle'),
                      items: [
                        for (var hour = 15; hour <= 23; hour++)
                          DropdownMenuItem(
                            value: hour,
                            child: Text('$hour:00'),
                          ),
                      ],
                      onChanged: (value) =>
                          value == null ? null : _updatePlan(endHour: value),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _saveGoal() async {
    final messenger = ScaffoldMessenger.of(context);
    final parsed = int.tryParse(_goal.text.trim());
    if (parsed == null ||
        parsed < WaterSettings.minimumGoalMilliliters ||
        parsed > WaterSettings.maximumGoalMilliliters) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('L’obiettivo deve stare tra 500 e 6000 ml.'),
        ),
      );
      return;
    }
    try {
      await ref.read(waterSettingsProvider.notifier).setGoal(parsed);
      messenger.showSnackBar(
        SnackBar(content: Text('Nuovo obiettivo: $parsed ml al giorno.')),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a salvare l’obiettivo.')),
      );
    }
  }

  Future<void> _toggleReminders({required bool enabled}) async {
    final messenger = ScaffoldMessenger.of(context)..removeCurrentSnackBar();
    final notifier = ref.read(waterSettingsProvider.notifier);
    try {
      if (!enabled) {
        await notifier.disableReminders();
        messenger.showSnackBar(
          const SnackBar(content: Text('Promemoria acqua disattivati.')),
        );
        return;
      }
      final granted = await notifier.enableReminders();
      if (!granted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Per i promemoria serve il permesso alle notifiche: '
              'puoi concederlo dalle impostazioni di sistema del telefono.',
            ),
          ),
        );
        return;
      }
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Promemoria attivi: ti scrivo io, tu bevi.'),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco ad aggiornare i promemoria.')),
      );
    }
  }

  Future<void> _updatePlan({
    int? intervalHours,
    int? startHour,
    int? endHour,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(waterSettingsProvider.notifier)
          .updateReminderPlan(
            intervalHours: intervalHours,
            startHour: startHour,
            endHour: endHour,
          );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco ad aggiornare i promemoria.')),
      );
    }
  }

  Future<void> _deleteEntry(WaterIntakeEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(wellbeingRepositoryProvider).deleteWater(entry.id);
      messenger.showSnackBar(
        SnackBar(content: Text('-${entry.milliliters} ml: tolti dal diario.')),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a eliminare questa voce.')),
      );
    }
  }
}

class _DayHistory extends StatelessWidget {
  const _DayHistory({required this.intake, required this.onDelete});

  final DailyWaterIntake intake;
  final void Function(WaterIntakeEntry entry) onDelete;

  @override
  Widget build(BuildContext context) {
    if (intake.entries.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Ancora nessun bicchiere registrato in questo giorno.',
            style: TextStyle(color: AppPalette.mutedInk),
          ),
        ),
      );
    }
    final time = DateFormat('HH:mm');
    return Card(
      child: Column(
        children: [
          for (final entry in intake.entries)
            ListTile(
              key: Key('water_entry_${entry.id}'),
              dense: true,
              leading: const Icon(
                Icons.water_drop_rounded,
                color: WaterPalette.deep,
                size: 20,
              ),
              title: Text(
                '${entry.milliliters} ml',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                'alle ${time.format(AppTime.inRome(entry.loggedAt))}',
                style: const TextStyle(color: AppPalette.mutedInk),
              ),
              trailing: IconButton(
                key: Key('water_entry_delete_${entry.id}'),
                tooltip: 'Elimina',
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                onPressed: () => onDelete(entry),
              ),
            ),
        ],
      ),
    );
  }
}

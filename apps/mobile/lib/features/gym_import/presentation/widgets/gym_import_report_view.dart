import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/gym_import/domain/gym_import_report.dart';
import 'package:kal_tracker/features/gym_import/presentation/widgets/gym_import_notice.dart';

/// Il rendiconto dell'import, uguale prima e dopo la scrittura.
///
/// È lo stesso widget per l'anteprima e per il risultato di proposito: se
/// Marco vede due layout diversi non può confrontarli, e confrontarli è
/// esattamente ciò che rende credibile la conferma.
///
/// I contatori sono raggruppati come nel `describe()` del rendiconto: sei
/// righe leggibili invece di quindici numeri sciolti, con i dettagli nella
/// didascalia. Niente viene nascosto — solo ordinato.
class GymImportReportView extends StatelessWidget {
  const GymImportReportView({required this.report, super.key});

  final GymImportReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: StatusChip(
            key: const Key('gym_import_dump_chip'),
            level: report.usedFirestoreDump
                ? AppStatusLevel.good
                : AppStatusLevel.warning,
            label: report.usedFirestoreDump
                ? 'Con il dump Firestore'
                : 'Senza dump Firestore',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          report.usedFirestoreDump
              ? 'Entrano anche prescrizioni, blocchi a tempo e pause '
                    'accumulate: quelle stanno solo nel dump.'
              : 'Prescrizioni delle schede, blocchi a tempo e pause '
                    'accumulate restano fuori: l\'export dell\'app non li '
                    'scriveva.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: accents.mutedInk,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 6),
        for (final (index, row) in _rows().indexed) ...[
          if (index > 0) const Divider(),
          row,
        ],
        if (report.syncMutations > 0) ...[
          const Divider(),
          StatRow(
            label: 'In coda di sincronizzazione',
            value: '${report.syncMutations}',
            icon: Icons.cloud_upload_rounded,
            caption: 'righe da mandare al server appena la sync li conosce',
          ),
        ],
        if (report.warnings.isNotEmpty) ...[
          const SizedBox(height: 14),
          GymImportNotice(
            key: const Key('gym_import_warnings'),
            icon: Icons.warning_amber_rounded,
            tone: GymImportNoticeTone.warning,
            title: _title(
              report.warnings.length,
              'Un dato storto, importato lo stesso',
              '${report.warnings.length} dati storti, importati lo stesso',
            ),
            lines: report.warnings,
          ),
        ],
        if (report.notImported.isNotEmpty) ...[
          const SizedBox(height: 10),
          GymImportNotice(
            key: const Key('gym_import_not_imported'),
            icon: Icons.filter_alt_off_rounded,
            tone: GymImportNoticeTone.info,
            title: 'Cosa resta fuori',
            message:
                'Nessuna tabella accoglie questi campi: non è un errore, è '
                'quello che il travaso non porta dentro.',
            lines: report.notImported,
          ),
        ],
      ],
    );
  }

  /// I sei gruppi. Le didascalie portano i conteggi di dettaglio: un numero
  /// grande per ogni cosa che Marco riconosce, il resto sotto.
  List<Widget> _rows() => [
    StatRow(
      key: const Key('gym_import_count_exercises'),
      label: 'Esercizi',
      value: '${report.exercises}',
      icon: Icons.fitness_center_rounded,
      caption: report.cooldownPresets == 0
          ? null
          : 'più ${_n(report.cooldownPresets, 'preset', 'preset')} di '
                'defaticamento',
    ),
    StatRow(
      key: const Key('gym_import_count_routines'),
      label: 'Schede',
      value: '${report.routines}',
      icon: Icons.list_alt_rounded,
      caption:
          '${_n(report.routineExercises, 'riga', 'righe')}, '
          '${_n(report.routineIntervalSegments, 'blocco a tempo', 'blocchi a tempo')}',
    ),
    StatRow(
      key: const Key('gym_import_count_weekly_plan'),
      label: 'Piano settimanale',
      value: '${report.weeklyPlanDays}',
      unit: report.weeklyPlanDays == 1 ? 'giorno' : 'giorni',
      unitSemantics: report.weeklyPlanDays == 1 ? 'giorno' : 'giorni',
      icon: Icons.calendar_month_rounded,
    ),
    StatRow(
      key: const Key('gym_import_count_workouts'),
      label: 'Sessioni',
      value: '${report.workouts}',
      icon: Icons.directions_run_rounded,
      caption:
          '${_n(report.workoutExercises, 'riga', 'righe')}, '
          '${_n(report.workoutSets, 'serie', 'serie')}, '
          '${_n(report.painPoints, 'punto dolente', 'punti dolenti')}',
    ),
    StatRow(
      key: const Key('gym_import_count_measurements'),
      label: 'Pesate',
      value: '${report.bodyMeasurements}',
      icon: Icons.monitor_weight_rounded,
      caption: _n(
        report.bodyMeasurementValues,
        'circonferenza',
        'circonferenze',
      ),
    ),
    StatRow(
      key: const Key('gym_import_count_achievements'),
      label: 'Trofei',
      value: '${report.achievements}',
      icon: Icons.emoji_events_rounded,
      caption: report.profileStats == 0
          ? 'XP e serie di giorni: già a posto'
          : 'con XP e serie di giorni',
    ),
  ];

  static String _title(int count, String singular, String plural) =>
      count == 1 ? singular : plural;

  static String _n(int count, String singular, String plural) =>
      '$count ${count == 1 ? singular : plural}';
}

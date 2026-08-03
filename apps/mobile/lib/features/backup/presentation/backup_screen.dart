import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/backup/data/backup_storage.dart';
import 'package:kal_tracker/features/backup/domain/backup_document.dart';
import 'package:kal_tracker/features/backup/domain/backup_restore.dart';
import 'package:kal_tracker/features/backup/presentation/backup_providers.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;
  BackupRestoreSummary? _summary;

  @override
  Widget build(BuildContext context) {
    ref.watch(backupAppVersionProvider);
    final state = ref
        .watch(backupStateProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => const BackupState.empty(),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Backup e ripristino'),
            Text(
              'Una copia del diario, quando vuoi',
              style: TextStyle(
                color: AppPalette.mutedInk,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        key: const Key('backup_list'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          const _BackupIntro(),
          const SizedBox(height: 14),
          _LastExportCard(
            state: state,
            busy: _busy,
            onExport: _export,
            onRestore: _restore,
          ),
          if (_summary != null) ...[
            const SizedBox(height: 14),
            _SummaryCard(summary: _summary!),
          ],
          const SizedBox(height: 14),
          const _BackupHint(),
        ],
      ),
    );
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final appVersion =
          ref.read(backupAppVersionProvider).valueOrNull ??
          BackupDocument.unknownAppVersion;
      final document = await ref
          .read(backupRepositoryProvider)
          .exportBackup(profileId: profile.id, appVersion: appVersion);
      final result = await ref
          .read(backupStorageProvider)
          .saveBackup(
            contents: document.encode(),
            exportedAt: document.exportedAt,
          );
      ref.invalidate(backupStateProvider);
      if (!mounted) {
        return;
      }
      _message(
        result.shared
            ? 'Backup pronto: ${document.rowCount} righe salvate.'
            : 'Backup salvato in ${result.path}',
      );
    } on Object {
      if (mounted) {
        _message('Non riesco a creare il backup.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _restore() async {
    final request = await showModalBottomSheet<_RestoreRequest>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const _RestoreSheet(),
    );
    if (request == null || !mounted) {
      return;
    }

    final confirmed = await _confirm(
      title: 'Ripristino il backup?',
      message:
          'Modalità scelta: ${request.mode.label.toLowerCase()}. '
          '${request.mode.description}',
      confirmLabel: 'Continua',
      confirmKey: const Key('confirm_restore_button'),
    );
    if (!confirmed || !mounted) {
      return;
    }

    if (request.mode == BackupRestoreMode.replace) {
      final replaceConfirmed = await _confirm(
        title: 'Sicuro di sostituire tutto?',
        message:
            'I dati che hai adesso sul telefono verranno cancellati e '
            'sostituiti con quelli del backup. Non si torna indietro.',
        confirmLabel: 'Sostituisci',
        confirmKey: const Key('confirm_replace_button'),
        destructive: true,
      );
      if (!replaceConfirmed || !mounted) {
        return;
      }
    }

    setState(() {
      _busy = true;
      _summary = null;
    });
    try {
      final contents = await ref
          .read(backupStorageProvider)
          .readRestoreSource(request.source);
      final summary = await ref
          .read(backupRepositoryProvider)
          .importBackup(contents, mode: request.mode);
      ref.invalidate(marcoProfileProvider);
      ref.invalidate(backupStateProvider);
      if (!mounted) {
        return;
      }
      setState(() => _summary = summary);
      _message(summary.message);
    } on BackupFormatException catch (error) {
      if (mounted) {
        _message(error.message);
      }
    } on Object {
      if (mounted) {
        _message('Non riesco a ripristinare il backup.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    required Key confirmKey,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: confirmKey,
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: AppPalette.coral)
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _BackupIntro extends StatelessWidget {
  const _BackupIntro();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppPalette.mintSoft,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: AppPalette.paper,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.backup_rounded,
                color: AppPalette.forest,
                size: 30,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Il diario vive solo qui',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'Il backup crea un file con tutto: pasti, obiettivi, '
                    'acqua, peso, alimenti, ricette e modelli. Salvalo dove '
                    'vuoi e ritrovi tutto anche su un telefono nuovo.',
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

class _LastExportCard extends StatelessWidget {
  const _LastExportCard({
    required this.state,
    required this.busy,
    required this.onExport,
    required this.onRestore,
  });

  final BackupState state;
  final bool busy;
  final Future<void> Function() onExport;
  final Future<void> Function() onRestore;

  @override
  Widget build(BuildContext context) {
    final lastExportAt = state.lastExportAt;
    final label = lastExportAt == null
        ? 'Non hai ancora fatto nessun backup.'
        : _lastExportLabel(AppTime.inRome(lastExportAt));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: AppPalette.yellowSoft,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: const Icon(
                    Icons.save_alt_rounded,
                    color: AppPalette.yellow,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'La tua copia di sicurezza',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        label,
                        key: const Key('last_export_at'),
                        style: const TextStyle(color: AppPalette.mutedInk),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('export_backup_button'),
              onPressed: busy ? null : onExport,
              icon: const Icon(Icons.ios_share_rounded),
              label: const Text('Esporta backup'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('restore_backup_button'),
              onPressed: busy ? null : onRestore,
              icon: const Icon(Icons.settings_backup_restore_rounded),
              label: const Text('Ripristina da file'),
            ),
          ],
        ),
      ),
    );
  }
}

String _lastExportLabel(DateTime moment) =>
    'Ultimo backup: ${DateFormat('d MMMM y', 'it').format(moment)} '
    'alle ${DateFormat('HH:mm', 'it').format(moment)}';

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final BackupRestoreSummary summary;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('restore_summary'),
      color: AppPalette.mintSoft,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: AppPalette.forest,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ripristino ${summary.mode.label.toLowerCase()} completato',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SummaryValue(
                    value: summary.created,
                    label: 'nuove',
                    color: AppPalette.forest,
                  ),
                ),
                Expanded(
                  child: _SummaryValue(
                    value: summary.updated,
                    label: 'aggiornate',
                    color: AppPalette.coral,
                  ),
                ),
                Expanded(
                  child: _SummaryValue(
                    value: summary.skipped,
                    label: 'invariate',
                    color: AppPalette.lilac,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({
    required this.value,
    required this.label,
    required this.color,
  });

  final int value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '$value',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        FittedBox(child: Text(label, style: const TextStyle(fontSize: 11))),
      ],
    );
  }
}

class _BackupHint extends StatelessWidget {
  const _BackupHint();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppPalette.lilacSoft,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Come funziona',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              '1. «Esporta backup» crea un file kal-tracker-backup-… e te lo '
              'apre: da lì puoi mandarlo dove preferisci.',
            ),
            const SizedBox(height: 6),
            const Text(
              '2. «Ripristina da file» ti chiede il percorso del file (o il '
              'suo contenuto) e ti fa scegliere se unire o sostituire.',
            ),
            const SizedBox(height: 6),
            const Text(
              '3. Prima di scrivere controlliamo che il file sia integro: se '
              'qualcosa non torna, il diario resta com’è.',
            ),
          ],
        ),
      ),
    );
  }
}

class _RestoreRequest {
  const _RestoreRequest({required this.source, required this.mode});

  final String source;
  final BackupRestoreMode mode;
}

class _RestoreSheet extends StatefulWidget {
  const _RestoreSheet();

  @override
  State<_RestoreSheet> createState() => _RestoreSheetState();
}

class _RestoreSheetState extends State<_RestoreSheet> {
  final _source = TextEditingController();
  BackupRestoreMode _mode = BackupRestoreMode.merge;
  String? _error;

  @override
  void dispose() {
    _source.dispose();
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Ripristina da file',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 5),
            const Text(
              'Incolla il percorso del file di backup oppure il suo '
              'contenuto: controlliamo tutto prima di toccare il diario.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('restore_source_field'),
              controller: _source,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: 'Percorso o contenuto del backup',
                errorText: _error,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              children: [
                for (final mode in BackupRestoreMode.values)
                  ChoiceChip(
                    key: Key('restore_mode_${mode.storageValue}'),
                    label: Text(mode.label),
                    selected: _mode == mode,
                    onSelected: (_) => setState(() => _mode = mode),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _mode.description,
              style: const TextStyle(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('restore_continue_button'),
              onPressed: _submit,
              icon: const Icon(Icons.arrow_forward_rounded),
              label: const Text('Continua'),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final source = _source.text.trim();
    if (source.isEmpty) {
      setState(() => _error = 'Serve il percorso o il contenuto del backup.');
      return;
    }
    Navigator.pop(context, _RestoreRequest(source: source, mode: _mode));
  }
}

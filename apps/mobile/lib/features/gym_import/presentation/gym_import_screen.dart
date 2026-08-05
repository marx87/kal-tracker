import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_providers.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_state.dart';
import 'package:kal_tracker/features/gym_import/presentation/widgets/gym_import_notice.dart';
import 'package:kal_tracker/features/gym_import/presentation/widgets/gym_import_report_view.dart';

/// Il travaso dello storico di Gym Tracker, in una schermata sola.
///
/// L'ordine dei gesti è il punto: si scelgono i file, si guarda cosa entra, e
/// solo allora si conferma. L'anteprima non è una stima ma l'import vero
/// annullato, quindi la conferma decide su numeri veri — è la regola dell'app,
/// la macchina propone e Marco conferma.
class GymImportScreen extends ConsumerStatefulWidget {
  const GymImportScreen({super.key});

  @override
  ConsumerState<GymImportScreen> createState() => _GymImportScreenState();
}

class _GymImportScreenState extends ConsumerState<GymImportScreen> {
  /// Quanto ci mette la lista a scendere fino al rendiconto: abbastanza da
  /// far capire che si è mossa, non tanto da far aspettare.
  static const Duration _revealDuration = Duration(milliseconds: 260);

  /// La lista deve poter scorrere da sola: il rendiconto nasce sotto il bordo
  /// dello schermo e senza controller resterebbe lì, invisibile.
  final ScrollController _list = ScrollController();

  /// Dove sta il rendiconto dentro la lista. È una chiave e non una posizione
  /// in pixel perché la card cambia altezza con quello che ha dentro.
  final GlobalKey _reportAnchor = GlobalKey();

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(gymImportControllerProvider);
    final accents = AppAccents.of(context);

    ref.listen(gymImportControllerProvider, _onStateChanged);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Porta dentro Gym Tracker'),
            Text(
              'Lo storico degli allenamenti, una volta sola',
              style: TextStyle(
                color: accents.mutedInk,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: AdaptiveContent(
        padded: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // L'errore sta FUORI dalla lista, sotto il titolo: dentro finiva
            // in fondo a una pagina che scorre e un import fallito sembrava
            // non essere mai partito. Due tentativi persi per davvero.
            if (state.error case final error?) ...[
              GymImportNotice(
                key: const Key('gym_import_error'),
                icon: Icons.dangerous_rounded,
                tone: GymImportNoticeTone.critical,
                title: 'Non ho importato niente',
                message: error,
              ),
              const SizedBox(height: 14),
            ],
            Expanded(
              child: ListView(
                key: const Key('gym_import_list'),
                controller: _list,
                children: [
                  const _IntroCard(),
                  const SizedBox(height: 14),
                  _FilesCard(
                    state: state,
                    onChooseExport: () => _chooseFile(isDump: false),
                    onChooseDump: () => _chooseFile(isDump: true),
                    onRemoveDump: _removeDump,
                  ),
                  const SizedBox(height: 14),
                  const _SyncNotice(),
                  if (state.step case final step?) ...[
                    const SizedBox(height: 14),
                    _ProgressCard(step: step),
                  ],
                  const SizedBox(height: 14),
                  KeyedSubtree(
                    key: _reportAnchor,
                    child: _ReportArea(state: state),
                  ),
                  const SizedBox(height: 16),
                  _ActionArea(state: state),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onStateChanged(GymImportState? previous, GymImportState next) {
    // Un rendiconto appena arrivato — anteprima o scrittura vera — nasce
    // sotto il bordo dello schermo: senza portarcelo, dopo «Vedi cosa entra»
    // sembra non essere successo niente.
    final reportArrived =
        (next.preview != null && previous?.preview == null) ||
        (next.result != null && previous?.result == null);
    if (reportArrived) {
      // Dopo il frame: adesso la card non esiste ancora nell'albero.
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealReport());
    }

    final error = next.error;
    if (error != null && error != previous?.error) {
      // Il riquadro rosso è in alto e si vede, ma chi usa il lettore di
      // schermo non ha un «in alto»: la frase gli va detta.
      SemanticsService.sendAnnouncement(
        View.of(context),
        error,
        Directionality.of(context),
      );
    }
  }

  /// Porta il rendiconto sotto gli occhi.
  ///
  /// Il primo tentativo può non trovare niente: la lista costruisce solo i
  /// figli dentro la viewport, e finché il rendiconto sta sotto il bordo la
  /// sua chiave non ha un contesto. Si scende allora in fondo — costruendolo —
  /// e si riprova. Il giro è limitato perché un ciclo che insegue una lista
  /// che cresce non finirebbe mai.
  Future<void> _revealReport() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!mounted) {
        return;
      }
      final target = _reportAnchor.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          duration: _revealDuration,
          curve: Curves.easeOut,
        );
        return;
      }
      if (!_list.hasClients) {
        return;
      }
      final position = _list.position;
      if (position.pixels >= position.maxScrollExtent) {
        return;
      }
      await _list.animateTo(
        position.maxScrollExtent,
        duration: _revealDuration,
        curve: Curves.easeOut,
      );
    }
  }

  /// Il foglio è l'unica porta: da lì si apre il selettore di sistema oppure
  /// si incolla il percorso. Tenere entrambe le strade non è indecisione —
  /// il selettore serve sul telefono, dove i Download non hanno un percorso
  /// che qualcuno conosca, e il percorso serve sul Mac e nei test.
  Future<void> _chooseFile({required bool isDump}) async {
    final controller = ref.read(gymImportControllerProvider.notifier);
    final choice = await showModalBottomSheet<_FileChoice>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) =>
          _FileSourceSheet(isDump: isDump, canBrowse: controller.canBrowse),
    );
    if (choice == null || !mounted) {
      return;
    }
    if (choice.source case final source?) {
      await (isDump
          ? controller.useDumpSource(source)
          : controller.useExportSource(source));
      return;
    }
    await (isDump ? controller.browseDump() : controller.browseExport());
  }

  void _removeDump() {
    final controller = ref.read(gymImportControllerProvider.notifier);
    final removed = controller.removeDump();
    if (removed == null) {
      return;
    }
    // Snackbar CON azione: su questo Flutter quelle non si chiudono da sole,
    // e l'helper è l'unico modo per cui «Annulla» resti disponibile senza
    // restare a schermo per sempre.
    showAutoClosingSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(
        content: Text('Tolto il dump «${removed.file.name}».'),
        action: SnackBarAction(
          label: 'Annulla',
          onPressed: () => controller.restoreDump(removed),
        ),
      ),
    );
  }
}

/// Cosa ha deciso il foglio: aprire il selettore di sistema, oppure usare il
/// percorso (o il contenuto) che è stato scritto.
class _FileChoice {
  const _FileChoice.browse() : source = null;
  const _FileChoice.source(String this.source);

  final String? source;
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    return const SectionCard(
      title: 'Lo storico di Gym Tracker',
      subtitle: 'Un travaso solo, che si può però rifare senza paura',
      icon: Icons.move_to_inbox_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IntroPoint(
            icon: Icons.folder_open_rounded,
            text:
                'Serve l\'export dell\'app. Il dump di Firestore è '
                'facoltativo: aggiunge prescrizioni, blocchi a tempo e pause.',
          ),
          SizedBox(height: 10),
          _IntroPoint(
            icon: Icons.visibility_rounded,
            text:
                'L\'anteprima è l\'import vero, fatto girare e annullato: i '
                'numeri che vedi prima di confermare sono quelli.',
          ),
          SizedBox(height: 10),
          _IntroPoint(
            icon: Icons.replay_rounded,
            text:
                'Rilanciarlo non crea doppioni: ciò che è già dentro viene '
                'riconosciuto dall\'id e saltato.',
          ),
        ],
      ),
    );
  }
}

class _IntroPoint extends StatelessWidget {
  const _IntroPoint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // L'icona non porta informazione da sola: ripete quello che la frase
        // dice già, quindi resta fuori dalla semantica.
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: theme.colorScheme.primary),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
          ),
        ),
      ],
    );
  }
}

class _FilesCard extends StatelessWidget {
  const _FilesCard({
    required this.state,
    required this.onChooseExport,
    required this.onChooseDump,
    required this.onRemoveDump,
  });

  final GymImportState state;
  final VoidCallback onChooseExport;
  final VoidCallback onChooseDump;
  final VoidCallback onRemoveDump;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'I due file',
      subtitle: 'Il primo è obbligatorio, il secondo no',
      icon: Icons.folder_open_rounded,
      child: Column(
        children: [
          _FileSlot(
            slotKey: const Key('gym_import_pick_export'),
            nameKey: const Key('gym_import_export_name'),
            title: 'Export di Gym Tracker',
            hint: 'Il file che l\'app ha generato con «Esporta».',
            icon: Icons.description_rounded,
            source: state.exportSource,
            required: true,
            enabled: !state.isBusy,
            onChoose: onChooseExport,
          ),
          const Divider(height: 26),
          _FileSlot(
            slotKey: const Key('gym_import_pick_dump'),
            nameKey: const Key('gym_import_dump_name'),
            title: 'Dump di Firestore',
            hint:
                'Facoltativo. Senza, l\'import gira lo stesso e il rendiconto '
                'dice cosa è rimasto fuori.',
            icon: Icons.cloud_download_rounded,
            source: state.dumpSource,
            required: false,
            enabled: !state.isBusy,
            onChoose: onChooseDump,
            onRemove: onRemoveDump,
          ),
        ],
      ),
    );
  }
}

class _FileSlot extends StatelessWidget {
  const _FileSlot({
    required this.slotKey,
    required this.nameKey,
    required this.title,
    required this.hint,
    required this.icon,
    required this.source,
    required this.required,
    required this.enabled,
    required this.onChoose,
    this.onRemove,
  });

  final Key slotKey;

  /// Chiave della riga che dice quale file è stato scelto: è quella che un
  /// test deve poter leggere senza inciampare in una snackbar omonima.
  final Key nameKey;

  final String title;
  final String hint;
  final IconData icon;
  final GymImportSource? source;
  final bool required;
  final bool enabled;
  final VoidCallback onChoose;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final chosen = source;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ExcludeSemantics(
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: chosen == null
                  ? theme.colorScheme.surfaceContainerHighest
                  : theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(
              chosen == null ? icon : Icons.check_rounded,
              size: 21,
              color: chosen == null
                  ? accents.mutedInk
                  : theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                required ? '$title (obbligatorio)' : '$title (facoltativo)',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                key: nameKey,
                chosen == null
                    ? hint
                    : '${chosen.file.name} (${chosen.file.sizeLabel})',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: slotKey,
          onPressed: enabled ? onChoose : null,
          child: Text(chosen == null ? 'Scegli' : 'Cambia'),
        ),
        if (chosen != null && onRemove != null)
          IconButton(
            key: const Key('gym_import_remove_dump'),
            onPressed: enabled ? onRemove : null,
            tooltip: 'Togli il dump',
            icon: const Icon(Icons.close_rounded),
          ),
      ],
    );
  }
}

/// L'avviso che nessuno ha voglia di scrivere e che invece va scritto: qui
/// dentro non si sincronizza niente, e non è un dettaglio tecnico.
class _SyncNotice extends StatelessWidget {
  const _SyncNotice();

  @override
  Widget build(BuildContext context) {
    // Il messaggio è cambiato quando la sincronizzazione ha imparato schede,
    // esercizi e sessioni: prima diceva che restava tutto sul telefono, e
    // continuare a dirlo sarebbe stato falso.
    return const GymImportNotice(
      key: Key('gym_import_sync_notice'),
      icon: Icons.cloud_sync_rounded,
      tone: GymImportNoticeTone.info,
      title: 'Lo storico si sincronizza',
      message:
          'Schede, esercizi e sessioni entrano nella coda di '
          'sincronizzazione insieme al resto: se la sincronizzazione è '
          'accesa arrivano anche sugli altri dispositivi. Il backup resta '
          'comunque la copia che non dipende da nessun server.',
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.step});

  final GymImportStep step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SectionCard(
      key: const Key('gym_import_progress'),
      title: 'Passo ${step.number} di ${GymImportStep.total}',
      subtitle: step.label,
      icon: Icons.hourglass_top_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepBar(step: step),
          const SizedBox(height: 10),
          Text(
            step == GymImportStep.writing
                ? 'Puoi anche uscire: la scrittura è dentro una sola '
                      'transazione, quindi o entra tutta o non entra niente.'
                : 'Ci metto qualche secondo: sto leggendo ogni sessione, '
                      'riga e serie.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tre segmenti, uno per passo: quelli fatti sono pieni, quello in corso
/// scorre, quelli da fare restano vuoti.
///
/// Non è una percentuale perché l'importer non ne espone una: il passo è
/// l'unica cosa vera che si possa mostrare, e mostrarla è meglio che
/// inventare un numero che avanza da solo.
class _StepBar extends StatelessWidget {
  const _StepBar({required this.step});

  final GymImportStep step;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      label:
          'Avanzamento dell\'import: passo ${step.number} di '
          '${GymImportStep.total}, ${step.label}',
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (var index = 1; index <= GymImportStep.total; index++) ...[
              if (index > 1) const SizedBox(width: 6),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 8,
                    child: index == step.number
                        ? LinearProgressIndicator(
                            backgroundColor: scheme.primaryContainer,
                            color: scheme.primary,
                          )
                        : ColoredBox(
                            color: index < step.number
                                ? scheme.primary
                                : scheme.outline,
                          ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// L'area del rendiconto: prima il segnaposto, poi l'anteprima, poi il
/// risultato. Uno solo dei tre alla volta.
class _ReportArea extends StatelessWidget {
  const _ReportArea({required this.state});

  final GymImportState state;

  @override
  Widget build(BuildContext context) {
    if (state.result case final result?) {
      return SectionCard(
        key: const Key('gym_import_result'),
        title: result.isNoop ? 'Non c\'era niente di nuovo' : 'Importato',
        subtitle: result.isNoop
            ? 'Lo storico era già qui: nessuna riga toccata.'
            : '${result.rowCount} righe nel diario, adesso.',
        icon: Icons.check_circle_rounded,
        child: GymImportReportView(report: result),
      );
    }

    if (state.preview case final preview?) {
      return SectionCard(
        key: const Key('gym_import_preview'),
        title: preview.isNoop ? 'Non entra niente' : 'Ecco cosa entra',
        subtitle: preview.isNoop
            ? 'È già tutto dentro: l\'import lo riconosce dagli id e non '
                  'duplica.'
            : '${preview.rowCount} righe, ancora da confermare. Non ho '
                  'scritto niente.',
        icon: preview.isNoop
            ? Icons.done_all_rounded
            : Icons.fact_check_rounded,
        child: GymImportReportView(report: preview),
      );
    }

    if (state.isBusy) {
      return const SizedBox.shrink();
    }

    return AppEmptyState(
      key: const Key('gym_import_empty'),
      icon: Icons.fact_check_rounded,
      title: 'Ancora nessuna anteprima',
      message: state.hasExport
          ? 'Chiedi l\'anteprima: ti dico riga per riga cosa entrerebbe, '
                'prima di scrivere qualsiasi cosa.'
          : 'Scegli l\'export di Gym Tracker: prima di scrivere ti mostro '
                'esattamente cosa entra.',
    );
  }
}

class _ActionArea extends ConsumerWidget {
  const _ActionArea({required this.state});

  final GymImportState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(gymImportControllerProvider.notifier);
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    if (state.isBusy) {
      return const SizedBox.shrink();
    }

    if (state.result != null) {
      return OutlinedButton.icon(
        key: const Key('gym_import_restart_button'),
        onPressed: controller.startOver,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Fai un altro import'),
      );
    }

    if (state.previewIsNoop) {
      return OutlinedButton.icon(
        key: const Key('gym_import_change_files_button'),
        onPressed: controller.backToFiles,
        icon: const Icon(Icons.folder_open_rounded),
        label: const Text('Prova con un altro file'),
      );
    }

    if (state.awaitsConfirmation) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            key: const Key('gym_import_confirm_button'),
            onPressed: controller.confirm,
            icon: const Icon(Icons.download_done_rounded),
            label: Text('Importa le ${state.preview!.rowCount} righe'),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('gym_import_back_button'),
            onPressed: controller.backToFiles,
            child: const Text('Torna ai file'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          key: const Key('gym_import_preview_button'),
          onPressed: state.canPreview ? controller.preview : null,
          icon: const Icon(Icons.visibility_rounded),
          label: const Text('Vedi cosa entra'),
        ),
        if (!state.hasExport) ...[
          const SizedBox(height: 8),
          Text(
            'Prima scegli l\'export di Gym Tracker.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: accents.mutedInk),
          ),
        ],
      ],
    );
  }
}

/// Il foglio con cui si indica un file: il selettore di sistema quando c'è,
/// altrimenti (o in alternativa) il percorso o il contenuto incollato.
class _FileSourceSheet extends StatefulWidget {
  const _FileSourceSheet({required this.isDump, required this.canBrowse});

  final bool isDump;

  /// Il bottone «Sfoglia» compare solo se c'è davvero un selettore da aprire:
  /// un bottone che non apre niente è peggio che non averlo.
  final bool canBrowse;

  @override
  State<_FileSourceSheet> createState() => _FileSourceSheetState();
}

class _FileSourceSheetState extends State<_FileSourceSheet> {
  final _source = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        18,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.isDump ? 'Il dump di Firestore' : 'L\'export di Gym',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              widget.canBrowse
                  ? 'Cercalo fra i file del telefono: di solito è in '
                        'Download. Prima di toccare qualsiasi cosa lo leggo e '
                        'te lo faccio vedere.'
                  : 'Incolla il percorso del file oppure il suo contenuto: '
                        'prima di toccare qualsiasi cosa lo leggo e te lo '
                        'faccio vedere.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
                height: 1.4,
              ),
            ),
            if (widget.canBrowse) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('gym_import_browse_button'),
                onPressed: () =>
                    Navigator.pop(context, const _FileChoice.browse()),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Sfoglia i file'),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      'oppure',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: accents.mutedInk,
                      ),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 12),
            ] else
              const SizedBox(height: 16),
            TextField(
              key: const Key('gym_import_source_field'),
              controller: _source,
              minLines: 2,
              maxLines: 5,
              // Con il selettore a portata di dito la tastiera che salta su
              // da sola coprirebbe proprio il bottone da premere.
              autofocus: !widget.canBrowse,
              decoration: InputDecoration(
                labelText: 'Percorso o contenuto del file',
                errorText: _error,
              ),
            ),
            const SizedBox(height: 16),
            // Quando c'è il selettore la strada principale è quella, e questa
            // conferma scende di tono: due bottoni pieni uno sopra l'altro
            // non direbbero da dove si passa di solito.
            if (widget.canBrowse)
              OutlinedButton.icon(
                key: const Key('gym_import_source_confirm'),
                onPressed: _submit,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('Usa questo file'),
              )
            else
              FilledButton.icon(
                key: const Key('gym_import_source_confirm'),
                onPressed: _submit,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('Usa questo file'),
              ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final source = _source.text.trim();
    if (source.isEmpty) {
      setState(() => _error = 'Serve il percorso oppure il contenuto.');
      return;
    }
    Navigator.pop(context, _FileChoice.source(source));
  }
}

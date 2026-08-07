import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';

/// Quello che il foglio restituisce: una limitazione da aprire, non ancora
/// aperta. Chi lo ha chiamato conosce il profilo e la data, qui si sceglie
/// solo cosa fa male e quanto.
@immutable
class LimitationDraft {
  const LimitationDraft({
    required this.bodyPart,
    required this.severity,
    this.note,
  });

  final BodyPart bodyPart;
  final LimitationSeverity severity;
  final String? note;
}

/// Apertura di una limitazione: prima l'articolazione, poi il lato, poi
/// quanto pesa.
///
/// La zona si sceglie in due passi e non da un elenco di quindici voci
/// perché è così che è fatto il dominio — un'articolazione e un lato — e
/// perché quindici pastiglie tutte insieme, con il testo al 150 %, sono uno
/// scorrimento e un errore di battitura.
///
/// **Nessuna data di fine.** Il foglio non la chiede e non la propone: una
/// limitazione si chiude quando Marco dice che è passata, non quando scade un
/// timer.
class LimitationSheet extends StatefulWidget {
  const LimitationSheet({super.key});

  @override
  State<LimitationSheet> createState() => _LimitationSheetState();
}

class _LimitationSheetState extends State<LimitationSheet> {
  final _note = TextEditingController();

  JointArea? _area;
  BodyPart? _part;
  LimitationSeverity? _severity;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// Le zone di quell'articolazione, nell'ordine dell'enum.
  static List<BodyPart> _partsOf(JointArea area) => BodyPart.values
      .where((part) => part.area == area)
      .toList(growable: false);

  /// Il lato scritto come si legge. `BodySide` non porta un'etichetta sua —
  /// è un enum di dominio, non di interfaccia — e `name` in mezzo a una
  /// pastiglia arriverebbe minuscolo.
  static String _sideLabel(BodySide side) => switch (side) {
    BodySide.destro => 'Destro',
    BodySide.sinistro => 'Sinistro',
    BodySide.centrale => 'Centrale',
  };

  void _pickArea(JointArea area) {
    final parts = _partsOf(area);
    setState(() {
      _area = area;
      // Collo, costole e lombari hanno una zona sola: chiedere «destra o
      // sinistra?» per un lombare sarebbe una domanda senza risposta.
      _part = parts.length == 1 ? parts.first : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final area = _area;
    final sides = area == null ? const <BodyPart>[] : _partsOf(area);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        key: const Key('limitation_sheet_scroll'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Cosa ti limita',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Serve a togliere dal catalogo quello che oggi non puoi fare. '
              'Resta aperta finché non la chiudi tu: nessuna scadenza '
              'automatica.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            const _FieldLabel(
              title: 'Dove',
              hint: 'L\'articolazione che sente il movimento.',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final option in JointArea.values)
                  _Choice(
                    itemKey: Key('limitation_area_${option.name}'),
                    label: option.label,
                    selected: option == _area,
                    onSelected: () => _pickArea(option),
                  ),
              ],
            ),
            if (sides.length > 1) ...[
              const SizedBox(height: 18),
              const _FieldLabel(
                title: 'Quale',
                hint:
                    'Il lato conta per lo storico. Nel filtro no: una spalla '
                    'ferma toglie anche quello che si fa con due.',
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final option in sides)
                    _Choice(
                      itemKey: Key('limitation_part_${option.storage}'),
                      label: _sideLabel(option.side),
                      selected: option == _part,
                      onSelected: () => setState(() => _part = option),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            const _FieldLabel(
              title: 'Quanto pesa',
              hint: 'Da quanto scegli qui dipende cosa sparisce dal catalogo.',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final option in LimitationSeverity.values)
                  _Choice(
                    itemKey: Key('limitation_severity_${option.name}'),
                    label: option.label,
                    selected: option == _severity,
                    onSelected: () => setState(() => _severity = option),
                  ),
              ],
            ),
            if (_severity case final severity?) ...[
              const SizedBox(height: 8),
              Text(
                severity.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 18),
            TextField(
              key: const Key('limitation_note_field'),
              controller: _note,
              maxLength: 300,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Nota (facoltativa)',
                helperText:
                    'Con parole tue: «rotazione esterna sopra i 90°». Fra tre '
                    'mesi sarà l\'unica cosa che spiega la scheda di adesso.',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('limitation_sheet_save_button'),
              onPressed: _part == null || _severity == null ? null : _submit,
              child: const Text('Apri la limitazione'),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('limitation_sheet_cancel_button'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Annulla'),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final part = _part;
    final severity = _severity;
    if (part == null || severity == null) {
      return;
    }
    final note = _note.text.trim();
    Navigator.of(context).pop(
      LimitationDraft(
        bodyPart: part,
        severity: severity,
        note: note.isEmpty ? null : note,
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.titleSmall),
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: accents.mutedInk,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

/// Una scelta singola, cresciuta fino al bersaglio da 48 come nei dati
/// personali: `ChoiceChip` e non `SegmentedButton` perché quello divide la
/// larghezza in parti fisse e con il testo grande taglia le etichette.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.itemKey,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final Key itemKey;
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: ChoiceChip(
        key: itemKey,
        selected: selected,
        // La spunta è il segnale ridondante al colore: chi non distingue il
        // verde vede comunque quale delle scelte è presa.
        showCheckmark: true,
        label: Text(label),
        labelPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        onSelected: (_) => onSelected(),
      ),
    );
  }
}

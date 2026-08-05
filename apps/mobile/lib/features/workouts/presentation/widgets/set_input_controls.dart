import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';

/// I comandi con cui si registra una serie: il pulsante −/valore/+, il
/// selettore di durata e la pastiglia dell'RPE.
///
/// I gesti sono quelli di Gym Tracker, collaudati in palestra col telefono
/// sudato: tocco sul valore per digitarlo esatto, trascinamento orizzontale
/// per scorrerlo, pressione prolungata sui capi per ripetere. Cambia il
/// vestito — niente più `BrandColors`, tutto da `colorScheme` e `AppAccents` —
/// e cambia il fatto che i bersagli non scendono mai sotto i 48.

/// La rampa di colore dell'RPE: verde → giallo → corallo su 1..10.
///
/// Non usa colori letterali. Passa dagli accenti semantici, quindi al buio
/// segue il tema invece di restare acceso su un fondo scuro. E siccome il
/// colore da solo non basta mai, la pastiglia mostra SEMPRE anche il numero.
Color rpeColor(BuildContext context, int value) {
  final accents = AppAccents.of(context);
  final t = ((value - 1) / 9).clamp(0.0, 1.0);
  if (t < 0.5) {
    return Color.lerp(accents.positive, accents.warning, t / 0.5)!;
  }
  return Color.lerp(accents.warning, accents.critical, (t - 0.5) / 0.5)!;
}

/// Come si legge un RPE ad alta voce, oltre al numero: chi ascolta non vede la
/// rampa di colore e «7» da solo non dice se è tanto o poco.
String rpeMeaning(int value) => switch (value) {
  <= 2 => 'molto facile',
  <= 4 => 'facile',
  <= 6 => 'impegnativo',
  <= 8 => 'duro',
  _ => 'quasi massimale',
};

/// Pulsante tondo che scatta al tocco e si ripete se lo tieni premuto.
class _RepeatButton extends StatefulWidget {
  const _RepeatButton({
    required this.icon,
    required this.onTrigger,
    required this.size,
    required this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback onTrigger;
  final double size;
  final String semanticLabel;

  @override
  State<_RepeatButton> createState() => _RepeatButtonState();
}

class _RepeatButtonState extends State<_RepeatButton> {
  Timer? _repeat;

  void _start() {
    widget.onTrigger();
    HapticFeedback.selectionClick();
    _repeat?.cancel();
    _repeat = Timer.periodic(
      const Duration(milliseconds: 110),
      (_) => widget.onTrigger(),
    );
  }

  void _stop() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      onTap: widget.onTrigger,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            widget.onTrigger();
            HapticFeedback.selectionClick();
          },
          onLongPressStart: (_) => _start(),
          onLongPressEnd: (_) => _stop(),
          onLongPressCancel: _stop,
          child: SizedBox.square(
            dimension: widget.size,
            child: Center(
              child: Container(
                width: widget.size,
                height: widget.size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.icon,
                  size: widget.size * 0.5,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La pastiglia condivisa −/valore/+.
class _StepperPill extends StatefulWidget {
  const _StepperPill({
    required this.value,
    required this.onMinus,
    required this.onPlus,
    required this.onTapValue,
    required this.semanticLabel,
    this.fieldKey,
  });

  /// Stringa vuota = valore non impostato.
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback onTapValue;
  final String semanticLabel;
  final Key? fieldKey;

  @override
  State<_StepperPill> createState() => _StepperPillState();
}

class _StepperPillState extends State<_StepperPill> {
  double _dragAccumulator = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final isEmpty = widget.value.isEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 48 quando c'è spazio. Sotto, si stringe invece di traboccare: il
        // valore centrale resta comunque toccabile e apre la digitazione
        // esatta, quindi nessuna funzione si perde.
        final buttonSize = constraints.maxWidth >= 132 ? 48.0 : 40.0;
        return Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 184),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RepeatButton(
                    icon: Icons.remove_rounded,
                    onTrigger: widget.onMinus,
                    size: buttonSize,
                    semanticLabel: 'Diminuisci ${widget.semanticLabel}',
                  ),
                  Expanded(
                    child: Semantics(
                      button: true,
                      label: isEmpty
                          ? '${widget.semanticLabel} non impostato. '
                                'Tocca per inserire.'
                          : '${widget.semanticLabel}: ${widget.value}. '
                                'Tocca per modificare.',
                      onTap: widget.onTapValue,
                      child: ExcludeSemantics(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.onTapValue,
                          onHorizontalDragStart: (_) => _dragAccumulator = 0,
                          // Ogni ~16 px un passo: è la sensibilità di Gym,
                          // trovata col telefono appoggiato sulla panca.
                          onHorizontalDragUpdate: (details) {
                            _dragAccumulator += details.delta.dx;
                            while (_dragAccumulator >= 16) {
                              _dragAccumulator -= 16;
                              widget.onPlus();
                            }
                            while (_dragAccumulator <= -16) {
                              _dragAccumulator += 16;
                              widget.onMinus();
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                isEmpty ? '–' : widget.value,
                                key: widget.fieldKey,
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: isEmpty
                                          ? accents.mutedInk
                                          : theme.colorScheme.onSurface,
                                    )
                                    .tabular,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _RepeatButton(
                    icon: Icons.add_rounded,
                    onTrigger: widget.onPlus,
                    size: buttonSize,
                    semanticLabel: 'Aumenta ${widget.semanticLabel}',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Il campo −/valore/+ per kg, ripetizioni e distanza.
class StepperField extends StatelessWidget {
  const StepperField({
    required this.value,
    required this.onMinus,
    required this.onPlus,
    required this.onTapValue,
    this.semanticLabel = 'valore',
    this.fieldKey,
    super.key,
  });

  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback onTapValue;
  final String semanticLabel;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) => _StepperPill(
    value: value,
    onMinus: onMinus,
    onPlus: onPlus,
    onTapValue: onTapValue,
    semanticLabel: semanticLabel,
    fieldKey: fieldKey,
  );
}

/// La durata come mm:ss, con gli stessi gesti del campo numerico: così una
/// serie a tempo si compila come una a ripetizioni, non come un modulo.
class DurationStepper extends StatelessWidget {
  const DurationStepper({
    required this.seconds,
    required this.onChanged,
    required this.onTapValue,
    this.step = 5,
    this.fieldKey,
    super.key,
  });

  /// `null` = non impostata.
  final int? seconds;

  /// Riceve i secondi totali nuovi, già limitati.
  final ValueChanged<int> onChanged;
  final VoidCallback onTapValue;
  final int step;
  final Key? fieldKey;

  static String formatDuration(int? seconds) {
    if (seconds == null) return '';
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$rest';
  }

  void _bump(int delta) => onChanged(((seconds ?? 0) + delta).clamp(0, 3599));

  @override
  Widget build(BuildContext context) => _StepperPill(
    value: formatDuration(seconds),
    onMinus: () => _bump(-step),
    onPlus: () => _bump(step),
    onTapValue: onTapValue,
    semanticLabel: 'durata',
    fieldKey: fieldKey,
  );
}

/// La pastiglia dello sforzo percepito. Aprendola si sceglie da 1 a 10.
class RpeChip extends StatelessWidget {
  const RpeChip({required this.value, required this.onChanged, super.key});

  final int? value;
  final ValueChanged<int?> onChanged;

  Future<void> _pick(BuildContext context) async {
    HapticFeedback.selectionClick();
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetContext) => _RpeSheet(selected: value),
    );
    if (picked == null) return;
    // -1 è il sentinella «cancella», scelto perché nessun RPE valido lo usa.
    onChanged(picked == -1 ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = value;
    final color = current == null
        ? AppAccents.of(context).mutedInk
        : rpeColor(context, current);

    return Semantics(
      button: true,
      label: current == null
          ? 'Sforzo percepito non impostato. Tocca per sceglierlo.'
          : 'Sforzo percepito $current su 10, ${rpeMeaning(current)}. '
                'Tocca per modificarlo.',
      onTap: () => _pick(context),
      child: ExcludeSemantics(
        child: InkWell(
          onTap: () => _pick(context),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: current == null ? 0.08 : 0.16),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withValues(alpha: 0.65)),
            ),
            child: Text(
              current == null ? 'RPE' : '$current',
              style:
                  (current == null
                          ? theme.textTheme.labelSmall
                          : theme.textTheme.titleMedium)
                      ?.copyWith(fontWeight: FontWeight.w900, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class _RpeSheet extends StatelessWidget {
  const _RpeSheet({required this.selected});

  final int? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Quanto è stata dura?',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '1 è una passeggiata, 10 è tutto quello che avevi.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var value = 1; value <= 10; value++)
                  _RpeOption(value: value, selected: selected == value),
              ],
            ),
            const SizedBox(height: 14),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(-1),
                child: const Text('Togli lo sforzo'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RpeOption extends StatelessWidget {
  const _RpeOption({required this.value, required this.selected});

  final int value;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = rpeColor(context, value);
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: 'Sforzo $value su 10, ${rpeMeaning(value)}',
      onTap: () => Navigator.of(context).pop(value),
      child: ExcludeSemantics(
        child: InkWell(
          onTap: () => Navigator.of(context).pop(value),
          borderRadius: BorderRadius.circular(15),
          child: Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: selected ? 1 : 0.16),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: color, width: selected ? 2.4 : 1),
            ),
            child: Text(
              '$value',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
                // Sopra il colore pieno serve un inchiostro che regga: il
                // fondo scelto è saturo, quello non selezionato è tenue.
                color: selected ? theme.colorScheme.onPrimary : color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Il foglio con cui si digita un numero esatto. Sostituisce
/// `showDialog` + `TextField` sparsi nella schermata di Gym: uno solo, con la
/// stessa forma degli altri fogli di Kal.
Future<double?> askExactNumber(
  BuildContext context, {
  required String title,
  required String unit,
  double? initialValue,
  bool decimal = true,
}) async {
  final controller = TextEditingController(
    text: initialValue == null
        ? ''
        : (initialValue % 1 == 0
              ? initialValue.toStringAsFixed(0)
              : initialValue.toString()),
  );
  final result = await showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: 20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: Theme.of(sheetContext).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(decimal: decimal),
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(labelText: title, suffixText: unit),
            onSubmitted: (raw) =>
                Navigator.of(sheetContext).pop(_parseNumber(raw)),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () =>
                Navigator.of(sheetContext).pop(_parseNumber(controller.text)),
            child: const Text('Conferma'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  return result;
}

/// La virgola italiana vale quanto il punto: sulla tastiera numerica di un
/// telefono in italiano è quella che si trova.
double? _parseNumber(String raw) {
  final cleaned = raw.trim().replaceAll(',', '.');
  if (cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/presentation/body_formats.dart';

/// Quello che il foglio restituisce a chi lo ha aperto: una pesata da
/// salvare, non ancora salvata.
@immutable
class WeighInDraft {
  const WeighInDraft({
    required this.weightKg,
    required this.measuredAt,
    this.bodyFatPct,
    this.musclePct,
    this.waterPct,
    this.impedanceOhm,
    this.note,
    this.circumferences = const {},
  });

  final double weightKg;

  /// Istante in UTC: il foglio maneggia ore di Roma, ma quello che esce di
  /// qui è già convertito, così chi salva non deve sapere niente di fusi.
  final DateTime measuredAt;

  final double? bodyFatPct;
  final double? musclePct;
  final double? waterPct;
  final double? impedanceOhm;
  final String? note;
  final Map<String, double> circumferences;

  bool get hasComposition => bodyFatPct != null;
}

/// Inserimento manuale di una pesata, con o senza impedenza.
///
/// Il peso è l'unico campo obbligatorio: la salita veloce a piedi asciutti dà
/// solo i kg, e quella pesata vale comunque: entra nella media del peso e
/// resta fuori da quella della composizione, invece di sparire.
///
/// Le circonferenze stanno qui e non in un foglio loro perché nel database
/// una misura a nastro appartiene a una pesata (`body_measurement_values` ha
/// la chiave verso `body_measurements`): senza pesata non ci sarebbe dove
/// attaccarle.
class WeighInSheet extends StatefulWidget {
  const WeighInSheet({required this.knownLabels, required this.now, super.key});

  /// Etichette di circonferenza già in uso, dalla più frequente.
  final List<String> knownLabels;

  /// Adesso, in ora di Roma: arriva da fuori così il foglio resta prevedibile
  /// nei test.
  final DateTime now;

  @override
  State<WeighInSheet> createState() => _WeighInSheetState();
}

class _WeighInSheetState extends State<WeighInSheet> {
  final _formKey = GlobalKey<FormState>();
  final _weight = TextEditingController();
  final _bodyFat = TextEditingController();
  final _muscle = TextEditingController();
  final _water = TextEditingController();
  final _impedance = TextEditingController();
  final _note = TextEditingController();
  final _circumferences = <String, TextEditingController>{};

  bool _withComposition = false;
  late DateTime _measuredAt;

  @override
  void initState() {
    super.initState();
    _measuredAt = widget.now;
    for (final label in widget.knownLabels.take(6)) {
      _circumferences[label] = TextEditingController();
    }
  }

  @override
  void dispose() {
    _weight.dispose();
    _bodyFat.dispose();
    _muscle.dispose();
    _water.dispose();
    _impedance.dispose();
    _note.dispose();
    for (final controller in _circumferences.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        key: const Key('weigh_in_scroll'),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Registra una pesata',
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Il peso basta. Se la bilancia ha letto anche la '
                'composizione, aggiungila: entrerà nelle medie a 7 giorni.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: accents.mutedInk,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              _WhenRow(moment: _measuredAt, onPick: _pickDay),
              const SizedBox(height: 14),
              _NumberField(
                key: const Key('weigh_in_weight_field'),
                controller: _weight,
                label: 'Peso (kg)',
                required: true,
                minimum: 20,
                maximum: 500,
              ),
              const SizedBox(height: 14),
              SwitchListTile(
                key: const Key('weigh_in_composition_switch'),
                value: _withComposition,
                contentPadding: EdgeInsets.zero,
                title: const Text('Anche la composizione'),
                subtitle: Text(
                  'Le percentuali che la bilancia mostra dopo l’impedenza.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: accents.mutedInk,
                  ),
                ),
                onChanged: (value) => setState(() => _withComposition = value),
              ),
              if (_withComposition) ...[
                const SizedBox(height: 10),
                _NumberField(
                  key: const Key('weigh_in_body_fat_field'),
                  controller: _bodyFat,
                  label: 'Grasso corporeo (%)',
                  required: true,
                  minimum: 1,
                  maximum: 80,
                  helper: 'Senza questa non si separa il grasso dalla magra.',
                ),
                const SizedBox(height: 10),
                _NumberField(
                  key: const Key('weigh_in_muscle_field'),
                  controller: _muscle,
                  label: 'Muscolo (%)',
                  minimum: 1,
                  maximum: 100,
                ),
                const SizedBox(height: 10),
                _NumberField(
                  key: const Key('weigh_in_water_field'),
                  controller: _water,
                  label: 'Acqua (%)',
                  minimum: 1,
                  maximum: 100,
                ),
                const SizedBox(height: 10),
                _NumberField(
                  key: const Key('weigh_in_impedance_field'),
                  controller: _impedance,
                  label: 'Impedenza (ohm)',
                  minimum: 1,
                  maximum: 2000,
                  helper:
                      'L’unica cosa che la bilancia misura davvero: se la '
                      'mostra, vale la pena conservarla.',
                ),
              ],
              const SizedBox(height: 20),
              Semantics(
                header: true,
                child: Text(
                  'Circonferenze (cm)',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Facoltative, e sempre legate a una pesata. Lascia vuoto '
                'quello che non hai misurato.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              for (final label in _circumferences.keys) ...[
                _NumberField(
                  key: Key('weigh_in_circumference_$label'),
                  controller: _circumferences[label]!,
                  label: label,
                  minimum: 1,
                  maximum: 1000,
                ),
                const SizedBox(height: 10),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('weigh_in_add_circumference'),
                  onPressed: _addCircumference,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Aggiungi una misura'),
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const Key('weigh_in_note_field'),
                controller: _note,
                maxLength: 240,
                decoration: const InputDecoration(
                  labelText: 'Nota (facoltativa)',
                  helperText: 'Per esempio: a digiuno, dopo la palestra.',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('save_weigh_in_button'),
                onPressed: _save,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Salva pesata'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _measuredAt,
      firstDate: DateTime(_measuredAt.year - 3),
      lastDate: widget.now,
      helpText: 'Quando ti sei pesato',
    );
    if (picked == null) {
      return;
    }
    setState(() {
      // Si cambia il giorno, non l'ora: l'ora della pesata resta quella
      // dichiarata, e a parità di giorno le pesate restano ordinate.
      _measuredAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _measuredAt.hour,
        _measuredAt.minute,
      );
    });
  }

  Future<void> _addCircumference() async {
    final label = await showDialog<String>(
      context: context,
      builder: (context) => const _NewCircumferenceDialog(),
    );
    if (label == null || label.isEmpty) {
      return;
    }
    if (_circumferences.containsKey(label)) {
      return;
    }
    setState(() => _circumferences[label] = TextEditingController());
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final circumferences = <String, double>{};
    for (final entry in _circumferences.entries) {
      final value = _parseNumber(entry.value.text);
      if (value != null) {
        circumferences[entry.key] = value;
      }
    }
    final note = _note.text.trim();

    Navigator.pop(
      context,
      WeighInDraft(
        weightKg: _parseNumber(_weight.text)!,
        // I campi di `_measuredAt` sono ora civile di Roma (arrivano da
        // `AppTime.nowInRome` o dal calendario): l'istante si costruisce qui.
        measuredAt: AppTime.fromRomeLocal(_measuredAt),
        bodyFatPct: _withComposition ? _parseNumber(_bodyFat.text) : null,
        musclePct: _withComposition ? _parseNumber(_muscle.text) : null,
        waterPct: _withComposition ? _parseNumber(_water.text) : null,
        impedanceOhm: _withComposition ? _parseNumber(_impedance.text) : null,
        note: note.isEmpty ? null : note,
        circumferences: circumferences,
      ),
    );
  }
}

class _WhenRow extends StatelessWidget {
  const _WhenRow({required this.moment, required this.onPick});

  final DateTime moment;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final accents = AppAccents.of(context);
    return Row(
      children: [
        Icon(Icons.event_rounded, size: 20, color: accents.mutedInk),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            // Ora da calendario, non istante: si formatta com'è.
            BodyFormats.wallDay(moment),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        TextButton(
          key: const Key('weigh_in_day_button'),
          onPressed: onPick,
          child: const Text('Cambia giorno'),
        ),
      ],
    );
  }
}

class _NewCircumferenceDialog extends StatefulWidget {
  const _NewCircumferenceDialog();

  @override
  State<_NewCircumferenceDialog> createState() =>
      _NewCircumferenceDialogState();
}

class _NewCircumferenceDialogState extends State<_NewCircumferenceDialog> {
  final _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Quale misura?'),
      content: TextField(
        key: const Key('new_circumference_label_field'),
        controller: _label,
        autofocus: true,
        maxLength: 40,
        decoration: const InputDecoration(
          labelText: 'Nome della misura',
          helperText: 'Per esempio: Fianchi, Collo, Polpaccio.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          key: const Key('confirm_new_circumference'),
          onPressed: () => Navigator.pop(context, _label.text.trim()),
          child: const Text('Aggiungi'),
        ),
      ],
    );
  }
}

/// Campo numerico in italiano: accetta la virgola, che è come si scrivono i
/// decimali su una tastiera italiana.
class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    this.required = false,
    this.minimum,
    this.maximum,
    this.helper,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final bool required;
  final double? minimum;
  final double? maximum;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]'))],
      decoration: InputDecoration(labelText: label, helperText: helper),
      validator: (value) {
        final text = (value ?? '').trim();
        if (text.isEmpty) {
          return required ? 'Serve un valore' : null;
        }
        final parsed = _parseNumber(text);
        if (parsed == null) {
          return 'Valore non valido';
        }
        if (minimum != null && parsed < minimum!) {
          return 'Minimo ${minimum!.round()}';
        }
        if (maximum != null && parsed > maximum!) {
          return 'Massimo ${maximum!.round()}';
        }
        return null;
      },
    );
  }
}

double? _parseNumber(String value) {
  final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
  return parsed != null && parsed.isFinite ? parsed : null;
}

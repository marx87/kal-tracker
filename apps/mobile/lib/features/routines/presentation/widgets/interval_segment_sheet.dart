import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/routines/domain/routine_draft.dart';

/// Apre il foglio di un blocco a tempo. Restituisce il blocco confermato,
/// oppure null se Marco esce.
Future<DraftSegment?> showIntervalSegmentSheet(
  BuildContext context, {
  required List<DraftExercise> main,
  required int initialStart,
  required int initialEnd,
  DraftSegment? existing,
}) => showModalBottomSheet<DraftSegment>(
  context: context,
  isScrollControlled: true,
  builder: (_) => IntervalSegmentSheet(
    main: main,
    initialStart: initialStart,
    initialEnd: initialEnd,
    existing: existing,
  ),
);

/// Un blocco a tempo dentro una scheda normale: da quale a quale esercizio,
/// quanto si lavora, quanto si recupera e quanti giri.
///
/// La finestra si sceglie per esercizio e non per indice: «da Squat a
/// Affondi» è una cosa che Marco riconosce, «da 3 a 5» no.
class IntervalSegmentSheet extends StatefulWidget {
  const IntervalSegmentSheet({
    required this.main,
    required this.initialStart,
    required this.initialEnd,
    this.existing,
    super.key,
  });

  final List<DraftExercise> main;

  /// Estremi iniziali, in forma semiaperta `[start, end)`.
  final int initialStart;
  final int initialEnd;

  final DraftSegment? existing;

  @override
  State<IntervalSegmentSheet> createState() => _IntervalSegmentSheetState();
}

class _IntervalSegmentSheetState extends State<IntervalSegmentSheet> {
  late int _start;
  late int _lastIncluded;
  late final TextEditingController _work;
  late final TextEditingController _rest;
  late final TextEditingController _longRest;
  late final TextEditingController _rounds;

  @override
  void initState() {
    super.initState();
    _start = widget.initialStart.clamp(0, widget.main.length - 1);
    // Dentro il foglio si ragiona sull'ULTIMO esercizio incluso: chiedere un
    // estremo escluso a chi compila una scheda è un tranello.
    _lastIncluded = (widget.initialEnd - 1).clamp(
      _start,
      widget.main.length - 1,
    );
    final existing = widget.existing;
    _work = TextEditingController(text: '${existing?.workSec ?? 40}');
    _rest = TextEditingController(text: '${existing?.restSec ?? 20}');
    _longRest = TextEditingController(text: '${existing?.longRestSec ?? 0}');
    _rounds = TextEditingController(text: '${existing?.rounds ?? 1}');
  }

  @override
  void dispose() {
    _work.dispose();
    _rest.dispose();
    _longRest.dispose();
    _rounds.dispose();
    super.dispose();
  }

  void _confirm() {
    final keys = [
      for (var index = _start; index <= _lastIncluded; index++)
        widget.main[index].key,
    ];
    Navigator.of(context).pop(
      DraftSegment(
        memberKeys: keys,
        workSec: _positive(_work.text, 40, max: 3600),
        restSec: _positive(_rest.text, 20, min: 0, max: 3600),
        longRestSec: _positive(_longRest.text, 0, min: 0, max: 3600),
        rounds: _positive(_rounds.text, 1, max: 50),
      ),
    );
  }

  static int _positive(
    String raw,
    int fallback, {
    int min = 1,
    int max = 3600,
  }) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) {
      return fallback;
    }
    return parsed.clamp(min, max);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final count = _lastIncluded - _start + 1;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: const Key('interval_segment_sheet'),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  widget.existing == null
                      ? 'Nuovo blocco a tempo'
                      : 'Blocco a tempo',
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Gli esercizi scelti si eseguono a tempo, uno dietro l\'altro, '
                'per il numero di giri indicato. Il resto della scheda resta '
                'a serie e ripetizioni.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              DropdownButtonFormField<int>(
                key: const Key('segment_start_field'),
                initialValue: _start,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Dal primo'),
                items: [
                  for (final (index, exercise) in widget.main.indexed)
                    DropdownMenuItem(
                      value: index,
                      child: Text(
                        '${index + 1}. ${exercise.name}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _start = value ?? _start;
                  if (_lastIncluded < _start) {
                    _lastIncluded = _start;
                  }
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: const Key('segment_end_field'),
                initialValue: _lastIncluded,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Fino a'),
                items: [
                  for (final (index, exercise) in widget.main.indexed)
                    if (index >= _start)
                      DropdownMenuItem(
                        value: index,
                        child: Text(
                          '${index + 1}. ${exercise.name}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                ],
                onChanged: (value) =>
                    setState(() => _lastIncluded = value ?? _lastIncluded),
              ),
              const SizedBox(height: 8),
              Text(
                count == 1
                    ? '1 esercizio a tempo.'
                    : '$count esercizi consecutivi a tempo.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _SecondsField(
                      fieldKey: const Key('segment_work_field'),
                      controller: _work,
                      label: 'Lavoro',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SecondsField(
                      fieldKey: const Key('segment_rest_field'),
                      controller: _rest,
                      label: 'Recupero',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _SecondsField(
                      fieldKey: const Key('segment_long_rest_field'),
                      controller: _longRest,
                      label: 'Pausa tra i giri',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('segment_rounds_field'),
                      controller: _rounds,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'Giri'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('segment_save_button'),
                onPressed: _confirm,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Applica'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecondsField extends StatelessWidget {
  const _SecondsField({
    required this.fieldKey,
    required this.controller,
    required this.label,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, suffixText: 'sec'),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';

/// Apre il foglio serie / ripetizioni / recupero di un esercizio dentro una
/// scheda. Restituisce null se Marco esce senza confermare, e una
/// prescrizione vuota quando sceglie di tornare ai valori predefiniti.
Future<ExercisePrescription?> showPrescriptionSheet(
  BuildContext context, {
  required String exerciseName,
  required ExerciseTrackingMode mode,
  required ExercisePrescription initial,
}) => showModalBottomSheet<ExercisePrescription>(
  context: context,
  isScrollControlled: true,
  builder: (_) => PrescriptionSheet(
    exerciseName: exerciseName,
    mode: mode,
    initial: initial,
  ),
);

/// Il foglio che rende finalmente visibile e modificabile la prescrizione
/// arrivata dall'export: prima esisteva nei dati e in nessuna schermata.
class PrescriptionSheet extends StatefulWidget {
  const PrescriptionSheet({
    required this.exerciseName,
    required this.mode,
    required this.initial,
    super.key,
  });

  final String exerciseName;
  final ExerciseTrackingMode mode;
  final ExercisePrescription initial;

  @override
  State<PrescriptionSheet> createState() => _PrescriptionSheetState();
}

class _PrescriptionSheetState extends State<PrescriptionSheet> {
  late final TextEditingController _sets;
  late final TextEditingController _work;
  late final TextEditingController _rest;

  bool get _timed => widget.mode.isTimed;

  @override
  void initState() {
    super.initState();
    _sets = TextEditingController(text: widget.initial.sets?.toString() ?? '');
    _work = TextEditingController(
      text:
          (_timed ? widget.initial.durationSec : widget.initial.reps)
              ?.toString() ??
          '',
    );
    _rest = TextEditingController(
      text: widget.initial.restSec?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _sets.dispose();
    _work.dispose();
    _rest.dispose();
    super.dispose();
  }

  void _confirm() {
    final work = int.tryParse(_work.text.trim());
    Navigator.of(context).pop(
      ExercisePrescription(
        sets: int.tryParse(_sets.text.trim()),
        reps: _timed ? null : work,
        durationSec: _timed ? work : null,
        restSec: int.tryParse(_rest.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: const Key('prescription_sheet'),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  widget.exerciseName,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Quante serie, quanto lavoro e quanto recupero. Lascia un '
                'campo vuoto per usare il valore predefinito.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('prescription_sets_field'),
                      controller: _sets,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: 'Serie',
                        hintText: '${PrescriptionDefaults.sets}',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('prescription_work_field'),
                      controller: _work,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: _timed ? 'Durata' : 'Ripetizioni',
                        hintText: _timed
                            ? '${PrescriptionDefaults.durationSec}'
                            : '${PrescriptionDefaults.reps}',
                        suffixText: _timed ? 'sec' : null,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('prescription_rest_field'),
                controller: _rest,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Recupero tra le serie',
                  hintText: '${PrescriptionDefaults.restSec}',
                  suffixText: 'sec',
                  // Zero non è «vuoto»: è la scelta di non riposare, quella
                  // che rende una coppia di esercizi una superserie vera.
                  helperText: '0 = nessun recupero · vuoto = predefinito',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('prescription_save_button'),
                onPressed: _confirm,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Applica'),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const Key('prescription_reset_button'),
                onPressed: () =>
                    Navigator.of(context).pop(ExercisePrescription.empty),
                child: const Text('Torna ai valori predefiniti'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

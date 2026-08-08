import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/workouts/domain/load_progression.dart';

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
  late final TextEditingController _workMax;
  late final TextEditingController _rest;

  /// Il tetto scritto non regge come intervallo. Compare solo dopo un
  /// tentativo di conferma: segnalare mentre si digita farebbe lampeggiare un
  /// errore a ogni cifra battuta.
  var _showRangeError = false;

  bool get _timed => widget.mode.isTimed;

  @override
  void initState() {
    super.initState();
    _sets = TextEditingController(text: widget.initial.sets?.toString() ?? '');
    _work = TextEditingController(
      text:
          (_timed
                  ? widget.initial.durationSec
                  : (widget.initial.range?.min ?? widget.initial.reps))
              ?.toString() ??
          '',
    );
    _workMax = TextEditingController(
      text: widget.initial.range?.max.toString() ?? '',
    );
    _rest = TextEditingController(
      text: widget.initial.restSec?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _sets.dispose();
    _work.dispose();
    _workMax.dispose();
    _rest.dispose();
    super.dispose();
  }

  int? _read(TextEditingController controller) =>
      int.tryParse(controller.text.trim());

  void _confirm() {
    final work = _read(_work);
    final top = _timed ? null : _read(_workMax);
    final range = RepRange.resolve(min: work, max: top);
    // Un tetto scritto che non forma un intervallo non si può né salvare né
    // ignorare in silenzio: sarebbe una banda promessa e mai applicata.
    if (top != null && range == null) {
      setState(() => _showRangeError = true);
      return;
    }
    Navigator.of(context).pop(
      ExercisePrescription(
        sets: _read(_sets),
        // Con l'intervallo le ripetizioni restano il suo fondo: è da lì che
        // la sessione riparte quando il carico sale.
        reps: _timed ? null : (range?.min ?? work),
        repsMin: range?.min,
        repsMax: range?.max,
        durationSec: _timed ? work : null,
        restSec: _read(_rest),
      ),
    );
  }

  /// Riempie il tetto con l'intervallo che la progressione propone per un
  /// numero fisso: `10` diventa `10-12`, non `8-12`.
  void _suggestRange(RepRange suggestion) {
    _workMax.text = '${suggestion.max}';
    setState(() => _showRangeError = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final suggestion = _timed ? null : RepRange.suggestedFor(_read(_work));

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
                      onChanged: (_) => setState(() => _showRangeError = false),
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
              if (!_timed) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const Key('prescription_reps_max_field'),
                  controller: _workMax,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() => _showRangeError = false),
                  decoration: InputDecoration(
                    labelText: 'Fino a (facoltativo)',
                    hintText: '12',
                    // È l'impostazione che accende la doppia progressione: se
                    // non si dice a cosa serve, resta un secondo numero senza
                    // motivo di esistere.
                    helperText: _showRangeError
                        ? null
                        : 'Vuoto = numero fisso. Con il tetto la scheda dice '
                              '«8-12» e l\'app può proporti il carico.',
                    helperMaxLines: 3,
                    errorText: _showRangeError
                        ? 'Il tetto deve stare sopra le ripetizioni: 8-12, '
                              'non 12-8.'
                        : null,
                    errorMaxLines: 2,
                  ),
                ),
                if (suggestion != null && _workMax.text.trim().isEmpty) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('prescription_suggest_range_button'),
                      onPressed: () => _suggestRange(suggestion),
                      icon: const Icon(Icons.trending_up_rounded, size: 18),
                      label: Text('Prova con ${suggestion.label}'),
                    ),
                  ),
                ],
              ],
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

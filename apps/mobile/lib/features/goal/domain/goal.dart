import 'package:kal_tracker/features/goal/domain/definition_level.dart';

/// Le tre fasi. Non sono etichette decorative: ognuna ha una regola diversa
/// su come si calcolano le calorie e su cosa conta come «tutto a posto».
enum GoalPhase {
  /// Deficit costante, proteine alte. Si ricalibra il deficit ogni
  /// settimana — **mai** l'obiettivo.
  approach(label: 'Avvicinamento'),

  /// Risalita graduale di ~100 kcal al giorno a settimana fino al
  /// mantenimento reale. Il peso che risale di un chilo è glicogeno e acqua:
  /// va spiegato, non subito.
  consolidation(label: 'Consolidamento'),

  /// Non un numero ma una banda. Dentro la banda non succede niente.
  maintenance(label: 'Mantenimento');

  const GoalPhase({required this.label});

  final String label;

  /// La regola della fase, in una frase.
  String get rule => switch (this) {
    GoalPhase.approach =>
      'Deficit costante e proteine alte. Ogni settimana si ricalibra il '
          'deficit, non il traguardo.',
    GoalPhase.consolidation =>
      'Si risale di circa 100 kcal al giorno ogni settimana. Il peso che '
          'torna su in questi giorni è glicogeno e acqua, non grasso.',
    GoalPhase.maintenance =>
      'Non c\'è un numero da centrare ma una banda. Dentro la banda va '
          'tutto bene.',
  };

  static GoalPhase fromStorage(String? value) {
    for (final phase in GoalPhase.values) {
      if (phase.name == value) {
        return phase;
      }
    }
    return GoalPhase.approach;
  }
}

/// Come si è chiuso un obiettivo passato.
enum GoalOutcome {
  reached(label: 'Raggiunto'),
  replaced(label: 'Cambiato in corsa'),
  abandoned(label: 'Archiviato');

  const GoalOutcome({required this.label});

  final String label;

  static GoalOutcome? fromStorage(String? value) {
    for (final outcome in GoalOutcome.values) {
      if (outcome.name == value) {
        return outcome;
      }
    }
    return null;
  }
}

/// **L'Obiettivo.**
///
/// Traguardo e ritmo sono entrambi parametri vivi: si cambiano quando si
/// vuole e il cambio ricalcola deficit e data stimata senza toccare lo
/// storico. Per questo l'entità porta anche lo stato di partenza
/// ([startWeightKg], [startFatFreeMassKg]): serve a misurare i progressi di
/// *questo* traguardo, mentre tendenze e TDEE misurato restano proprietà del
/// corpo e sopravvivono a qualunque cambio.
class Goal {
  const Goal({
    required this.id,
    required this.targetWeightKg,
    required this.targetLevel,
    required this.paceKgPerWeek,
    required this.startedAt,
    required this.startWeightKg,
    required this.startFatFreeMassKg,
    this.phase = GoalPhase.approach,
    this.phaseStartedAt,
    this.closedAt,
    this.outcome,
  });

  factory Goal.fromJson(Map<String, Object?> json) {
    final startedAt = _readDate(json['started_at']);
    return Goal(
      id: (json['id'] as String?) ?? '',
      targetWeightKg: _readDouble(json['target_weight_kg']) ?? 0,
      targetLevel:
          DefinitionLevel.fromStorage(json['target_level'] as String?) ??
          DefinitionLevel.normal,
      paceKgPerWeek: _readDouble(json['pace_kg_per_week']) ?? 0.5,
      startedAt: startedAt ?? DateTime.utc(2026),
      startWeightKg: _readDouble(json['start_weight_kg']) ?? 0,
      startFatFreeMassKg: _readDouble(json['start_fat_free_mass_kg']) ?? 0,
      phase: GoalPhase.fromStorage(json['phase'] as String?),
      phaseStartedAt: _readDate(json['phase_started_at']),
      closedAt: _readDate(json['closed_at']),
      outcome: GoalOutcome.fromStorage(json['outcome'] as String?),
    );
  }

  final String id;

  /// Il peso traguardo, in chili. È la metà «numerica» della scelta.
  final double targetWeightKg;

  /// La definizione traguardo. È la metà «a parole», e le due si muovono
  /// insieme sulla manopola.
  final DefinitionLevel targetLevel;

  /// Quanti chili a settimana. Vive qui e non in una costante di codice
  /// proprio perché si cambia in corsa.
  final double paceKgPerWeek;

  final DateTime startedAt;
  final double startWeightKg;
  final double startFatFreeMassKg;

  final GoalPhase phase;

  /// Quando è iniziata la fase corrente: serve al consolidamento, che risale
  /// di 100 kcal per ogni settimana trascorsa.
  final DateTime? phaseStartedAt;

  final DateTime? closedAt;
  final GoalOutcome? outcome;

  bool get isOpen => closedAt == null;

  /// Come si dice a voce: «80,5 kg definito».
  String get headline =>
      '${_formatKg(targetWeightKg)} kg ${targetLevel.inlineLabel}';

  Goal copyWith({
    double? targetWeightKg,
    DefinitionLevel? targetLevel,
    double? paceKgPerWeek,
    GoalPhase? phase,
    DateTime? phaseStartedAt,
    DateTime? closedAt,
    GoalOutcome? outcome,
  }) => Goal(
    id: id,
    targetWeightKg: targetWeightKg ?? this.targetWeightKg,
    targetLevel: targetLevel ?? this.targetLevel,
    paceKgPerWeek: paceKgPerWeek ?? this.paceKgPerWeek,
    startedAt: startedAt,
    startWeightKg: startWeightKg,
    startFatFreeMassKg: startFatFreeMassKg,
    phase: phase ?? this.phase,
    phaseStartedAt: phaseStartedAt ?? this.phaseStartedAt,
    closedAt: closedAt ?? this.closedAt,
    outcome: outcome ?? this.outcome,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'target_weight_kg': targetWeightKg,
    'target_level': targetLevel.name,
    'pace_kg_per_week': paceKgPerWeek,
    'started_at': startedAt.toUtc().toIso8601String(),
    'start_weight_kg': startWeightKg,
    'start_fat_free_mass_kg': startFatFreeMassKg,
    'phase': phase.name,
    'phase_started_at': phaseStartedAt?.toUtc().toIso8601String(),
    'closed_at': closedAt?.toUtc().toIso8601String(),
    'outcome': outcome?.name,
  };
}

/// L'obiettivo di adesso più quelli di prima.
///
/// Cambiare idea a metà percorso è un'operazione normale: il vecchio
/// obiettivo non sparisce, si archivia. Lo storico è la prova che il
/// percorso è continuo anche quando il traguardo si sposta.
class GoalHistory {
  const GoalHistory({this.current, this.past = const []});

  factory GoalHistory.fromJson(Map<String, Object?> json) {
    final rawCurrent = json['current'];
    final rawPast = json['past'];
    return GoalHistory(
      current: rawCurrent is Map<String, Object?>
          ? Goal.fromJson(rawCurrent)
          : null,
      past: rawPast is List
          ? [
              for (final item in rawPast)
                if (item is Map<String, Object?>) Goal.fromJson(item),
            ]
          : const [],
    );
  }

  const GoalHistory.empty() : current = null, past = const [];

  final Goal? current;
  final List<Goal> past;

  bool get hasGoal => current != null;

  Map<String, Object?> toJson() => {
    'current': current?.toJson(),
    'past': [for (final goal in past) goal.toJson()],
  };
}

/// La banda di mantenimento: **non un numero, un intervallo**.
///
/// Dentro la banda non scatta nessun allarme. È la differenza tra un piano
/// che regge e uno che chiede di centrare 87,4 kg tutti i giorni.
class MaintenanceBand {
  const MaintenanceBand({required this.lowKg, required this.highKg});

  /// La banda intorno al traguardo: un chilo sotto e uno sopra.
  factory MaintenanceBand.around(double weightKg, {double halfWidthKg = 1}) =>
      MaintenanceBand(
        lowKg: weightKg - halfWidthKg,
        highKg: weightKg + halfWidthKg,
      );

  final double lowKg;
  final double highKg;

  BandStatus statusOf(double sevenDayAverageKg) {
    if (sevenDayAverageKg < lowKg) {
      return BandStatus.below;
    }
    if (sevenDayAverageKg > highKg) {
      return BandStatus.above;
    }
    return BandStatus.inside;
  }

  /// Come si scrive: «86,5 – 88,5 kg».
  String get label => '${_formatKg(lowKg)} – ${_formatKg(highKg)} kg';
}

enum BandStatus {
  inside(label: 'Dentro la banda'),
  above(label: 'Sopra la banda'),
  below(label: 'Sotto la banda');

  const BandStatus({required this.label});

  final String label;
}

/// La regola di rientro: si riapre un ciclo **solo** se la media a 7 giorni
/// esce dalla banda dalla stessa parte per due settimane consecutive.
///
/// Una settimana fuori non è una tendenza: è un compleanno, un viaggio, o
/// tre giorni di sale in più.
abstract final class MaintenanceWatch {
  static const int consecutiveWeeksBeforeAction = 2;

  /// [weeklyAverages] in ordine cronologico, l'ultima settimana per ultima.
  static bool needsNewCycle({
    required MaintenanceBand band,
    required List<double> weeklyAverages,
  }) {
    if (weeklyAverages.length < consecutiveWeeksBeforeAction) {
      return false;
    }
    final recent = weeklyAverages
        .skip(weeklyAverages.length - consecutiveWeeksBeforeAction)
        .map(band.statusOf)
        .toList(growable: false);
    final first = recent.first;
    if (first == BandStatus.inside) {
      return false;
    }
    return recent.every((status) => status == first);
  }
}

String _formatKg(double value) => value.toStringAsFixed(1).replaceAll('.', ',');

double? _readDouble(Object? value) {
  if (value is num && value.isFinite) {
    return value.toDouble();
  }
  return null;
}

DateTime? _readDate(Object? value) {
  if (value is! String) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}

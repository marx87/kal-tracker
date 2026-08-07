/// **Lo screening degli esercizi.**
///
/// Dato un esercizio del catalogo e il profilo di allenamento, dice una di tre
/// cose: è libero, va segnalato con un'alternativa, oppure è fuori. È il
/// lavoro che il 7 agosto 2026 Marco ha fatto a mano, esercizio per esercizio,
/// per costruire una scheda con una spalla che non regge le spinte sopra la
/// testa — e che senza questo file andrebbe rifatto identico a ogni scheda.
///
/// **Resta una proposta.** Lo screening non cancella niente e non riscrive
/// nessuna scheda: produce un esito e la ragione per cui l'ha prodotto, e
/// chi guarda decide.
library;

import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';

/// Quanto lavora un'articolazione in un esercizio.
enum JointRole {
  /// È lei a fare il movimento: nella shoulder press la spalla, nel curl il
  /// gomito. Se fa male, l'esercizio non ha un modo di esistere più leggero.
  primaria,

  /// Lavora, ma non è lei l'esercizio: il polso che regge il manubrio, la
  /// zona lombare che tiene il busto nello squat. Qui il carico si può quasi
  /// sempre spostare cambiando presa, appoggio o escursione.
  secondaria,
}

/// I tre esiti possibili.
enum ScreeningOutcome {
  /// Nessuna limitazione lo tocca e l'attrezzatura c'è.
  libero,

  /// Si può fare, ma con un'alternativa pronta accanto.
  segnalato,

  /// Fuori, e c'è scritto perché.
  escluso,
}

/// Un requisito di attrezzatura: è soddisfatto se il profilo ha **almeno uno**
/// degli attrezzi elencati (un goblet squat lo regge un manubrio o un
/// kettlebell, indifferentemente).
@immutable
class EquipmentRequirement {
  const EquipmentRequirement(this.label, this.options);

  /// Un attrezzo che una casa non ha: cavi, lat machine, leg press, tapis
  /// roulant.
  ///
  /// La lista di alternative è **vuota di proposito**, e non è un buco:
  /// [Equipment] descrive un appartamento, non una palestra, quindi nessuna
  /// voce del profilo può soddisfare questo requisito. Dirlo qui è meglio che
  /// lasciar credere che quell'esercizio sia disponibile.
  const EquipmentRequirement.gymOnly(this.label)
    : options = const <Equipment>{};

  final String label;
  final Set<Equipment> options;

  bool isMetBy(Set<Equipment> owned) => options.any(owned.contains);
}

/// L'esito per un esercizio, con la ragione.
@immutable
class ExerciseScreening {
  const ExerciseScreening({
    required this.exerciseId,
    required this.outcome,
    this.reason,
    this.alternative,
    this.limitations = const [],
    this.missingEquipment = const [],
  });

  const ExerciseScreening.free(this.exerciseId)
    : outcome = ScreeningOutcome.libero,
      reason = null,
      alternative = null,
      limitations = const [],
      missingEquipment = const [];

  final String exerciseId;
  final ScreeningOutcome outcome;

  /// Perché, in una frase leggibile. Nullo solo quando l'esito è [libero]:
  /// non c'è niente da spiegare quando non si toglie niente.
  final String? reason;

  /// Cosa fare al posto suo. Presente **sempre** quando l'esito è
  /// [segnalato]: segnalare senza dire come aggirare l'ostacolo sposta il
  /// lavoro su Marco invece di toglierglielo.
  final String? alternative;

  /// Le limitazioni aperte che hanno prodotto l'esito.
  final List<TrainingLimitation> limitations;

  /// I requisiti di attrezzatura non soddisfatti.
  final List<EquipmentRequirement> missingEquipment;

  bool get isExcluded => outcome == ScreeningOutcome.escluso;
  bool get isFlagged => outcome == ScreeningOutcome.segnalato;
  bool get isFree => outcome == ScreeningOutcome.libero;
}

/// Il setaccio.
abstract final class ExerciseScreener {
  /// L'esito di un esercizio per questo profilo.
  ///
  /// L'ordine dei controlli non è casuale:
  /// 1. **le limitazioni aperte**, perché se una parte del corpo è ferma
  ///    quello è il motivo che Marco deve leggere — comprare l'attrezzo
  ///    mancante non sbloccherebbe comunque l'esercizio;
  /// 2. **l'attrezzatura**, che esclude ciò che in casa non si può fare;
  /// 3. quel che resta è libero.
  static ExerciseScreening screen({
    required Exercise exercise,
    required TrainingProfile profile,
  }) {
    final joints = jointsOf(exercise);

    // La più grave fra le limitazioni che toccano questo esercizio: due
    // limitazioni aperte insieme (spalla in fastidio, polso in stop) devono
    // dare l'esito della peggiore, non quello della prima trovata.
    TrainingLimitation? worst;
    JointRole? worstRole;
    for (final limitation in profile.activeLimitations) {
      final role = joints[limitation.bodyPart.area];
      if (role == null) {
        continue;
      }
      if (worst == null ||
          limitation.severity.rank > worst.severity.rank ||
          (limitation.severity == worst.severity &&
              role == JointRole.primaria &&
              worstRole == JointRole.secondaria)) {
        worst = limitation;
        worstRole = role;
      }
    }

    if (worst != null && worstRole != null) {
      final excluded = _excludes(worst.severity, worstRole);
      if (excluded) {
        return ExerciseScreening(
          exerciseId: exercise.id,
          outcome: ScreeningOutcome.escluso,
          reason: _limitationReason(worst, worstRole, excluded: true),
          limitations: [worst],
        );
      }
    }

    final missing = _missingEquipment(exercise, profile);
    if (missing.isNotEmpty) {
      return ExerciseScreening(
        exerciseId: exercise.id,
        outcome: ScreeningOutcome.escluso,
        reason: _equipmentReason(missing),
        missingEquipment: missing,
      );
    }

    if (worst != null && worstRole != null) {
      return ExerciseScreening(
        exerciseId: exercise.id,
        outcome: ScreeningOutcome.segnalato,
        reason: _limitationReason(worst, worstRole, excluded: false),
        alternative: _alternativeFor(exercise, worst.bodyPart.area),
        limitations: [worst],
      );
    }

    return ExerciseScreening.free(exercise.id);
  }

  /// Lo stesso setaccio su un catalogo intero, per id.
  static Map<String, ExerciseScreening> screenAll({
    required Iterable<Exercise> exercises,
    required TrainingProfile profile,
  }) => {
    for (final exercise in exercises)
      exercise.id: screen(exercise: exercise, profile: profile),
  };

  /// Le articolazioni che un esercizio carica, e con che ruolo.
  ///
  /// **È un'euristica sul nome, e va detto.** La tabella `exercises` porta il
  /// gruppo muscolare ma non le articolazioni: finché non le porterà, il
  /// gruppo dà la base (il petto lavora di spalla e gomito, sempre) e il nome
  /// la corregge, perché è lì che sta la differenza fra una panca piana e una
  /// spinta sopra la testa. Le regole sotto sono scritte a partire dai 322
  /// nomi del catalogo vero di Marco, non da una tassonomia generale: su un
  /// esercizio scritto con parole diverse riconoscerà di meno, mai di più.
  /// Nel dubbio la mappa **aggiunge** un'articolazione invece di ometterla:
  /// un esercizio segnalato di troppo si scarta leggendo, uno mancato fa
  /// male.
  static Map<JointArea, JointRole> jointsOf(Exercise exercise) {
    final loaded = <JointArea, JointRole>{};
    void add(JointArea area, JointRole role) {
      // Una primaria non retrocede mai a secondaria: se una regola più
      // precisa ha già detto «è lei a fare il movimento», la base del gruppo
      // muscolare non la contraddice.
      if (loaded[area] == JointRole.primaria) {
        return;
      }
      loaded[area] = role;
    }

    for (final entry in _byMuscleGroup[exercise.muscleGroup] ?? const []) {
      add(entry.area, entry.role);
    }
    final name = _normalize(exercise.name);
    for (final rule in _jointRules) {
      if (rule.matches(name)) {
        add(rule.area, rule.role);
      }
    }
    return Map.unmodifiable(loaded);
  }

  /// Cosa serve per farlo. Stessa avvertenza: si legge dal nome.
  static List<EquipmentRequirement> requirementsOf(Exercise exercise) {
    final name = _normalize(exercise.name);
    final requirements = <EquipmentRequirement>[];

    // **L'attrezzo portante è uno solo, e vince la prima regola che
    // riconosce il nome.** Se «Swing con manubrio» chiedesse insieme il
    // manubrio (per «manubrio») e il kettlebell (per «swing») risulterebbe
    // escluso proprio a chi ha l'attrezzo che il nome dichiara.
    for (final rule in _mainToolRules) {
      if (rule.matches(name)) {
        requirements.add(rule.requirement);
        break;
      }
    }

    // Il supporto e l'ancoraggio sono indipendenti dall'attrezzo portante:
    // una panca inclinata con i manubri chiede tutte e due le cose.
    if (_matchesAny(name, _benchKeywords)) {
      requirements.add(
        const EquipmentRequirement('una panca', {Equipment.pancaRegolabile}),
      );
    }
    if (_matchesAny(name, _anchorKeywords)) {
      requirements.add(_anchorRequirement);
    }

    return List.unmodifiable(requirements);
  }

  static List<EquipmentRequirement> _missingEquipment(
    Exercise exercise,
    TrainingProfile profile,
  ) {
    // Silenzio non è un no. Un profilo appena creato non ha dichiarato
    // niente: filtrarlo come «non ha nulla» toglierebbe di colpo tutto il
    // catalogo, e la prima schermata di Marco sarebbe una lista vuota.
    if (!profile.hasDeclaredEquipment) {
      return const [];
    }
    return requirementsOf(exercise)
        .where((requirement) => !requirement.isMetBy(profile.equipment))
        .toList(growable: false);
  }

  /// `stop` esclude qualunque cosa carichi quella zona, anche di striscio.
  /// `dolore` esclude solo quando è quell'articolazione a fare il movimento:
  /// sul ruolo secondario resta una segnalazione, perché lì il carico si
  /// sposta cambiando presa o appoggio.
  static bool _excludes(LimitationSeverity severity, JointRole role) =>
      severity == LimitationSeverity.stop ||
      (severity == LimitationSeverity.dolore && role == JointRole.primaria);

  static String _limitationReason(
    TrainingLimitation limitation,
    JointRole role, {
    required bool excluded,
  }) {
    final zona = limitation.bodyPart.label.toLowerCase();
    final carico = role == JointRole.primaria
        ? 'è l\'articolazione che fa il movimento'
        : 'lavora comunque';
    if (excluded) {
      return limitation.severity == LimitationSeverity.stop
          ? 'Fuori: $zona è in stop e questo esercizio la carica.'
          : 'Fuori: $zona fa male e $carico.';
    }
    return 'Da tenere d\'occhio: $zona dà fastidio e $carico.';
  }

  static String _equipmentReason(List<EquipmentRequirement> missing) {
    final what = missing.map((requirement) => requirement.label).join(' e ');
    return 'Fuori: serve $what, e non è fra le cose che hai.';
  }

  /// L'alternativa da proporre quando l'esito è [ScreeningOutcome.segnalato].
  ///
  /// Prima si prova a essere precisi sul movimento (una spinta sopra la testa
  /// ha una sostituzione ovvia: la stessa spinta sotto la linea della spalla),
  /// poi si ripiega sul principio generale dell'articolazione. Il ripiego
  /// copre tutte le zone, così una segnalazione non resta mai senza risposta.
  static String _alternativeFor(Exercise exercise, JointArea area) {
    final name = _normalize(exercise.name);
    for (final rule in _alternativeRules) {
      if (rule.area == area && rule.matches(name)) {
        return rule.text;
      }
    }
    return _alternativeByArea[area]!;
  }

  static String _normalize(String value) => value.toLowerCase().trim();

  static bool _matchesAny(String name, List<String> keywords) =>
      keywords.any(name.contains);
}

/// Un'articolazione con il suo ruolo, per la mappa di base.
@immutable
class _JointLoad {
  const _JointLoad(this.area, this.role);

  final JointArea area;
  final JointRole role;
}

/// Una regola sul nome: se una delle parole compare, quell'articolazione
/// lavora con quel ruolo.
@immutable
class _JointRule {
  const _JointRule(this.keywords, this.area, this.role);

  final List<String> keywords;
  final JointArea area;
  final JointRole role;

  bool matches(String name) => keywords.any(name.contains);
}

@immutable
class _ToolRule {
  const _ToolRule(this.keywords, this.requirement);

  final List<String> keywords;
  final EquipmentRequirement requirement;

  bool matches(String name) => keywords.any(name.contains);
}

@immutable
class _AlternativeRule {
  const _AlternativeRule(this.area, this.keywords, this.text);

  final JointArea area;
  final List<String> keywords;
  final String text;

  bool matches(String name) => keywords.any(name.contains);
}

/// **La base: cosa lavora sempre, per gruppo muscolare.**
///
/// Non descrive l'esercizio, descrive la regione. Un esercizio di petto passa
/// dalla spalla e dal gomito qualunque cosa sia, ed è per questo che una
/// spalla in stop toglie anche le croci. Il nome poi corregge e aggiunge.
const _byMuscleGroup = <MuscleGroup, List<_JointLoad>>{
  MuscleGroup.petto: [
    _JointLoad(JointArea.spalla, JointRole.primaria),
    _JointLoad(JointArea.gomito, JointRole.secondaria),
    _JointLoad(JointArea.polso, JointRole.secondaria),
  ],
  MuscleGroup.spalle: [
    _JointLoad(JointArea.spalla, JointRole.primaria),
    _JointLoad(JointArea.gomito, JointRole.secondaria),
    _JointLoad(JointArea.collo, JointRole.secondaria),
  ],
  MuscleGroup.schiena: [
    _JointLoad(JointArea.spalla, JointRole.primaria),
    _JointLoad(JointArea.gomito, JointRole.secondaria),
    _JointLoad(JointArea.lombari, JointRole.secondaria),
  ],
  MuscleGroup.bicipiti: [
    _JointLoad(JointArea.gomito, JointRole.primaria),
    _JointLoad(JointArea.spalla, JointRole.secondaria),
    _JointLoad(JointArea.polso, JointRole.secondaria),
  ],
  MuscleGroup.tricipiti: [
    _JointLoad(JointArea.gomito, JointRole.primaria),
    _JointLoad(JointArea.spalla, JointRole.secondaria),
    _JointLoad(JointArea.polso, JointRole.secondaria),
  ],
  MuscleGroup.gambe: [
    _JointLoad(JointArea.ginocchio, JointRole.primaria),
    _JointLoad(JointArea.anca, JointRole.primaria),
    _JointLoad(JointArea.lombari, JointRole.secondaria),
    _JointLoad(JointArea.caviglia, JointRole.secondaria),
  ],
  MuscleGroup.polpacci: [
    _JointLoad(JointArea.caviglia, JointRole.primaria),
    _JointLoad(JointArea.ginocchio, JointRole.secondaria),
  ],
  MuscleGroup.addome: [
    _JointLoad(JointArea.lombari, JointRole.secondaria),
    _JointLoad(JointArea.costole, JointRole.secondaria),
  ],
  MuscleGroup.cardio: [
    _JointLoad(JointArea.ginocchio, JointRole.secondaria),
    _JointLoad(JointArea.caviglia, JointRole.secondaria),
    _JointLoad(JointArea.anca, JointRole.secondaria),
  ],
  // Full body, mobilità e «altro» non hanno una base: sotto quei tre gruppi
  // sta di tutto, dal saluto al sole al turkish get-up. Decide solo il nome.
};

/// **Le regole sul nome.** Sono l'euristica dichiarata sopra: parole prese
/// dal catalogo reale, non una classificazione anatomica.
const _jointRules = <_JointRule>[
  // Spalla. Tutto ciò che spinge o solleva sopra la linea delle spalle, più
  // le trazioni e i movimenti a braccio teso: è la lista che il 7 agosto
  // Marco ha depennato a mano una voce per volta.
  _JointRule(
    [
      'shoulder press',
      'military press',
      'overhead',
      'sopra la testa',
      'sopra testa',
      'lento dietro',
      'arnold press',
      'push press',
      'z press',
      'landmine press',
      'cuban press',
      'bradford press',
      'clean and press',
      'thruster',
      'snatch',
      'handstand',
      'pike push-up',
      'alzate',
      'upright row',
      'y-raise',
      'reverse flyes',
      'face pull',
      'croci',
      'pec-deck',
      'pullover',
      'dip',
      'trazioni',
      'chin-up',
      'pull-up',
      'lat machine',
      'pulldown',
      'push-up',
      'push up',
      'flessioni',
      'panca',
      'chest press',
      'floor press',
      'shoulder cars',
      'shoulder dislocations',
      'wall slides',
      'rotazioni esterne',
      'turkish get-up',
      'muscle-up',
    ],
    JointArea.spalla,
    JointRole.primaria,
  ),
  // Gomito: i movimenti che lo aprono e lo chiudono sotto carico.
  _JointRule(
    [
      'curl',
      'push-down',
      'pushdown',
      'french press',
      'skull crusher',
      'estensioni tricipiti',
      'kickback',
      'jm press',
      'tate press',
      'california press',
      'presa stretta',
      'close-grip',
      'dip',
      '21s',
    ],
    JointArea.gomito,
    JointRole.primaria,
  ),
  // Polso. La lista nasce da un caso concreto: con il polso messo male sono
  // le mani a terra a fare male, non il petto. Tutto ciò che appoggia il
  // palmo o resta appeso lo carica di suo.
  _JointRule(
    [
      'push-up',
      'push up',
      'flessioni',
      'plank',
      'burpee',
      'bear crawl',
      'mountain climber',
      'handstand',
      'renegade row',
      'curl polsi',
      'farmer walk',
      'dead hang',
      'sospensione alla sbarra',
      'toes to bar',
      'presa',
      'trazioni',
      'ab rollout',
      'wall ball',
      'battle ropes',
    ],
    JointArea.polso,
    JointRole.primaria,
  ),
  // Collo: le scrollate lo caricano direttamente, e il crunch lo tira quando
  // le mani finiscono dietro la nuca.
  _JointRule(['shrugs', 'scrollate'], JointArea.collo, JointRole.primaria),
  _JointRule(
    ['crunch', 'sit-up', 'v-up', 'overhead', 'sopra la testa'],
    JointArea.collo,
    JointRole.secondaria,
  ),
  // Costole: flessioni e torsioni del busto, e tutto ciò che appende il corpo
  // ai dorsali, che sulle coste ci si attaccano.
  _JointRule(
    [
      'crunch',
      'sit-up',
      'russian twist',
      'woodchopper',
      'torsione',
      'v-up',
      'hollow',
      'trazioni',
      'pullover',
      'l-sit',
    ],
    JointArea.costole,
    JointRole.secondaria,
  ),
  // Lombari: schiena sotto carico, con il busto che deve tenere.
  _JointRule(
    [
      'stacco',
      'good morning',
      'hyperextension',
      'rematore',
      'seal row',
      'pendlay',
      't-bar',
      'superman',
      'rack pull',
      'clean',
      'snatch',
      'swing',
      'zercher',
      'front squat',
      'back squat',
      'squat bilanciere',
      'overhead squat',
      'farmer walk',
      'turkish get-up',
    ],
    JointArea.lombari,
    JointRole.primaria,
  ),
  // Anca: piegare, spingere e distendere il bacino.
  _JointRule(
    [
      'squat',
      'affondi',
      'lunge',
      'stacco',
      'hip thrust',
      'ponte glutei',
      'glute',
      'step-up',
      'leg press',
      'good morning',
      'pistol',
      'cossack',
      'split squat',
      'bulgaro',
      'swing',
      'estensione anca',
      'abductor',
      'adductor',
      'hip cars',
    ],
    JointArea.anca,
    JointRole.primaria,
  ),
  // Ginocchio: piegamento sotto carico e atterraggi.
  _JointRule(
    [
      'squat',
      'affondi',
      'lunge',
      'leg extension',
      'leg press',
      'leg curl',
      'step-up',
      'jump',
      'salti',
      'pistol',
      'sissy',
      'wall sit',
      'hack squat',
      'nordic curl',
      'split squat',
      'bulgaro',
      'burpee',
      'skater',
      'high knees',
      'ginocchia alte',
      'sprint',
      'skip',
    ],
    JointArea.ginocchio,
    JointRole.primaria,
  ),
  // Caviglia: spinta di piede e impatti a terra.
  _JointRule(
    [
      'calf',
      'polpacci',
      'jump',
      'salti',
      'corda per saltare',
      'skip',
      'sprint',
      'corsa',
      'tapis roulant',
      'tibialis',
      'ankle mobility',
      'box jump',
      'skater',
      'high knees',
      'ginocchia alte',
    ],
    JointArea.caviglia,
    JointRole.primaria,
  ),
];

/// **L'attrezzo portante**, in ordine di precedenza: vince la prima regola che
/// riconosce il nome. Chi dichiara il proprio attrezzo («con manubrio», «con
/// elastico») deve essere letto prima di chi lo suggerisce solo con la
/// famiglia del movimento («swing», «goblet»).
const _mainToolRules = <_ToolRule>[
  _ToolRule([
    'manubri',
    'manubrio',
    'hex press',
    'arnold press',
  ], EquipmentRequirement('i manubri', {Equipment.manubri})),
  _ToolRule([
    'kettlebell',
    'turkish get-up',
  ], EquipmentRequirement('un kettlebell', {Equipment.kettlebell})),
  // Il goblet lo regge indifferentemente un manubrio o un kettlebell: è una
  // presa, non un attrezzo.
  _ToolRule(
    ['goblet'],
    EquipmentRequirement('un manubrio o un kettlebell', {
      Equipment.manubri,
      Equipment.kettlebell,
    }),
  ),
  _ToolRule([
    'bilanciere',
    'barbell',
    'landmine',
    'rack pull',
    'trap bar',
    'zercher',
    'front squat',
    'back squat',
    'power clean',
    'clean bilanciere',
  ], EquipmentRequirement('un bilanciere', {Equipment.bilanciere})),
  // «Elastico» senza altro: va bene di qualunque tipo. Se poi il movimento
  // chiede un ancoraggio, è la regola dell'ancoraggio a dirlo.
  _ToolRule(
    ['elastic'],
    EquipmentRequirement('un elastico', {
      Equipment.elasticiAdAnello,
      Equipment.elasticiAncorabili,
    }),
  ),
  _ToolRule([
    'machine',
    'macchina',
    'ai cavi',
    'al cavo',
    'cavi ',
    'pulley',
    'leg press',
    'leg extension',
    'leg curl',
    'pec-deck',
    'hack squat',
    'smith',
    'abductor',
    'adductor',
    'cyclette',
    'ellittica',
    'vogatore',
    'tapis roulant',
    'stair climber',
    'sled',
    'hyperextension',
    'battle ropes',
  ], EquipmentRequirement.gymOnly('un attrezzo da palestra')),
  _ToolRule(
    [
      'trazioni',
      'chin-up',
      'pull-up',
      'dead hang',
      'sospensione alla sbarra',
      'toes to bar',
      'hanging leg raise',
      'muscle-up',
      'sbarra',
    ],
    EquipmentRequirement('una sbarra per trazioni', {Equipment.sbarraTrazioni}),
  ),
];

/// Serve una panca. Una panca regolabile fa anche la piana, quindi la voce
/// del profilo è una sola.
const _benchKeywords = <String>['panca', 'seal row', 'spider', 'preacher'];

/// **Serve un punto di ancoraggio.** È la regola che ha fatto nascere la
/// distinzione fra elastici ad anello e ancorabili: senza un gancio sopra la
/// testa il push-down non esiste, e non c'è un modo di farlo più leggero.
const _anchorKeywords = <String>[
  'push-down',
  'pushdown',
  'pulldown',
  'lat machine',
  'pulley',
  'ai cavi',
  'al cavo',
  'face pull',
  'pallof',
  'woodchopper',
  'rotazioni esterne',
  'estensione anca in piedi',
];

const _anchorRequirement = EquipmentRequirement(
  'un punto di ancoraggio (cavi o elastici ancorabili)',
  {Equipment.elasticiAncorabili},
);

/// Le alternative precise, per movimento. Sono poche di proposito: una
/// sostituzione sbagliata vale meno di un consiglio generico ma onesto.
const _alternativeRules = <_AlternativeRule>[
  _AlternativeRule(
    JointArea.spalla,
    [
      'shoulder press',
      'military press',
      'overhead',
      'sopra la testa',
      'sopra testa',
      'lento dietro',
      'arnold press',
      'push press',
      'thruster',
    ],
    'Spingi su panca inclinata a 45° invece che sopra la testa: stesso '
    'lavoro, spalla sotto la linea che dà fastidio.',
  ),
  _AlternativeRule(
    JointArea.spalla,
    ['alzate'],
    'Fermale all\'altezza delle spalle, presa neutra e carico più leggero: '
    'oltre quel punto il fastidio non aggiunge muscolo.',
  ),
  _AlternativeRule(
    JointArea.spalla,
    ['panca', 'croci', 'chest press', 'dip'],
    'Gomiti più vicini al busto e fermata prima del piano del petto, oppure '
    'floor press: la spalla non va dietro la linea del corpo.',
  ),
  _AlternativeRule(
    JointArea.spalla,
    ['push-up', 'flessioni'],
    'Mani più in alto (flessioni inclinate): meno escursione sotto il piano '
    'del petto, stessa spinta.',
  ),
  _AlternativeRule(
    JointArea.spalla,
    ['trazioni', 'chin-up', 'pull-up', 'lat machine', 'pulldown'],
    'Passa alla presa neutra e non scendere a braccia del tutto distese: è '
    'l\'ultimo tratto a tirare.',
  ),
  _AlternativeRule(
    JointArea.gomito,
    ['curl'],
    'Presa a martello e fermata prima della distensione completa: il gomito '
    'non arriva a fine corsa.',
  ),
  _AlternativeRule(
    JointArea.gomito,
    ['push-down', 'french press', 'skull crusher', 'estensioni tricipiti'],
    'Sostituisci con una spinta a presa stretta: il tricipite lavora senza '
    'aprire e chiudere il gomito a braccio fermo.',
  ),
  _AlternativeRule(
    JointArea.ginocchio,
    ['jump', 'salti', 'sprint', 'skip', 'burpee'],
    'Togli la fase in volo: stesso esercizio senza stacco da terra, o passo '
    'veloce al posto del salto.',
  ),
  _AlternativeRule(
    JointArea.lombari,
    ['stacco', 'rematore', 'good morning'],
    'Fai lo stesso tiro con il petto appoggiato alla panca: toglie alla '
    'schiena il compito di tenere il busto.',
  ),
];

/// Il ripiego per articolazione. Copre tutte le zone: una segnalazione senza
/// una via d'uscita rimanderebbe a Marco il lavoro che questo file esiste per
/// togliergli.
const _alternativeByArea = <JointArea, String>{
  JointArea.spalla:
      'Tieni le mani sotto la linea delle spalle e riduci l\'escursione: '
      'quasi tutto quello che serve si fa anche lì.',
  JointArea.gomito:
      'Presa neutra e fermata prima del blocco: il gomito lavora in mezzo, '
      'non agli estremi.',
  JointArea.polso:
      'Impugna manubri o maniglie invece di appoggiare il palmo a terra: il '
      'polso resta dritto.',
  JointArea.collo:
      'Sguardo avanti e mani incrociate al petto invece che dietro la nuca.',
  JointArea.costole:
      'Niente torsioni né flessioni cariche del busto: tienilo neutro, plank '
      'al posto del crunch.',
  JointArea.lombari:
      'Sposta il carico via dalla schiena: stesso movimento da sdraiato o '
      'con il petto appoggiato.',
  JointArea.anca:
      'Riduci l\'escursione e togli la rotazione: mezzo affondo con appoggio '
      'invece del movimento completo.',
  JointArea.ginocchio: 'Fermati dove non tira (box squat) e togli i salti.',
  JointArea.caviglia:
      'Lavora da seduto e senza impatti: niente corsa e niente balzi finché '
      'non passa.',
};

/// **La progressione del carico.**
///
/// L'app registra i carichi, calcola i massimali stimati e mostra i record —
/// e non ha mai un'opinione su cosa fare la prossima volta. La scheda dice
/// 3×10 e continua a dirlo per sempre, finché non è Marco a riscriverla a
/// mano: è metà del mestiere di un coach, ed è la metà che manca.
///
/// **La doppia progressione** è la regola più semplice che funziona davvero.
/// La prescrizione non è un numero ma un intervallo — `8-12` invece di `10`,
/// che è a cosa servono le colonne `presc_reps_min`/`presc_reps_max` della
/// v9. Dentro l'intervallo si sale di ripetizioni a parità di carico; quando
/// TUTTE le serie arrivano in cima, il carico sale di un gradino e le
/// ripetizioni tornano in fondo. Le due leve si alternano, e nessuna delle
/// due si tocca a occhio.
///
/// **Propone, non applica.** Qui non si scrive niente: [LoadProgression.advise]
/// restituisce un verdetto, un numero e le ragioni per cui l'ha prodotto. La
/// scheda la cambia Marco.
///
/// Niente database: si leggono serie già lette.
library;

import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';
import 'package:kal_tracker/features/workouts/domain/personal_records.dart';
import 'package:kal_tracker/features/workouts/domain/plate_calculator.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// L'intervallo di ripetizioni: **`8-12`, non `10`**.
///
/// Con un numero fisso non esiste il momento in cui salire di carico — o si
/// centra il numero o non lo si centra, e la scheda resta uguale a sé stessa
/// per mesi. L'intervallo dà alla progressione i due estremi che le servono:
/// un tetto da raggiungere e un fondo dove tornare quando il carico sale.
@immutable
class RepRange {
  const RepRange({required this.min, required this.max});

  /// L'intervallo com'è scritto sulla riga di scheda.
  ///
  /// Nullo quando quell'intervallo non c'è **o non è un intervallo**: le due
  /// colonne della v9 sono nullable e senza CHECK, e un `12-12` arrivato da
  /// una sincronizzazione è un numero fisso travestito — trattarlo come una
  /// banda farebbe proporre un gradino a ogni seduta.
  ///
  /// Il ripiego su [suggestedFor] non si fa qui di proposito: quello è una
  /// PROPOSTA di intervallo, e chi la usa deve poterlo dire a Marco invece di
  /// vedersela apparire come se fosse scritta sulla scheda.
  static RepRange? resolve({int? min, int? max}) {
    if (min == null || max == null || min < 1 || max <= min) {
      return null;
    }
    return RepRange(min: min, max: max);
  }

  /// Di quanto si allarga verso l'alto un numero fisso: **due ripetizioni**.
  static const int widenBy = 2;

  /// L'intervallo da PROPORRE a una riga che ha ancora solo `presc_reps`.
  ///
  /// Le schede di oggi dicono `3×10` e basta, e riscriverle a mano una per
  /// una non succederà mai: senza un ripiego la doppia progressione resta
  /// spenta su tutto lo storico di Marco.
  ///
  /// **Si allarga solo verso l'alto**, ed è la decisione che conta: `10`
  /// diventa `10-12` e non `8-12`. Un intervallo aperto verso il basso
  /// autorizzerebbe otto ripetizioni dove la scheda ne chiedeva dieci — la
  /// proposta renderebbe la seduta più facile, che è l'ultima cosa che deve
  /// fare. Verso l'alto invece il vecchio numero resta il pavimento, e quando
  /// il carico sale le ripetizioni ci tornano sopra: la scheda di prima,
  /// con qualche chilo in più.
  ///
  /// Le due ripetizioni di ampiezza sono un'euristica: su una prescrizione da
  /// tre allargano parecchio in proporzione, ed è il motivo per cui questo
  /// resta un suggerimento da confermare.
  static RepRange? suggestedFor(int? fixedReps) {
    if (fixedReps == null || fixedReps < 1) {
      return null;
    }
    return RepRange(min: fixedReps, max: fixedReps + widenBy);
  }

  /// Estremi INCLUSI: dodici ripetizioni su `8-12` sono in cima, non un
  /// soffio oltre.
  final int min;
  final int max;

  /// Come si scrive accanto alle serie: «8-12».
  String get label => '$min-$max';

  bool contains(int reps) => reps >= min && reps <= max;

  /// Vero anche oltre il tetto: chi ne fa quattordici su `8-12` il tetto
  /// l'ha superato, e fingere di no bloccherebbe la progressione proprio dove
  /// il carico è più chiaramente troppo leggero.
  bool isAtTop(int reps) => reps >= max;
}

/// **Il gradino di carico**: il salto più piccolo che l'attrezzatura vera
/// consente.
///
/// Non è una percentuale. Il 2,5% teorico su 18 kg fa 450 grammi, che con dei
/// manubri che salgono di 2 in 2 non esistono: la proposta sarebbe un numero
/// che Marco non può caricare. Il gradino lo decide il ferro che c'è in casa,
/// e per questo si legge da [Equipment].
@immutable
class LoadStep {
  const LoadStep._({required this.reason, this.kg, this.tool});

  /// I manubri componibili salgono aggiungendo un dischetto per lato, che
  /// nelle serie da casa è **1 kg per lato: 2 kg per manubrio**.
  ///
  /// L'assunzione da dichiarare è un'altra, ed è sul dato registrato: il
  /// campo `weightKg` di una serie con i manubri porta il peso di UN manubrio,
  /// non la somma dei due. Se un giorno si decidesse di registrare la coppia,
  /// questo gradino andrebbe raddoppiato insieme al resto.
  static const double dumbbellStepKg = 2;

  /// I kettlebell del mercato italiano vanno di 4 in 4 (8, 12, 16, 20, 24):
  /// non è un gradino fine — da 16 a 20 sono venticinque punti percentuali in
  /// una volta — ma è l'unico che esiste, e proporne uno più piccolo
  /// significherebbe proporre un attrezzo che Marco non ha.
  static const double kettlebellStepKg = 4;

  /// Il bilanciere sale di una COPPIA di dischi, uno per lato: il disco più
  /// piccolo della lista di `plate_calculator` vale il doppio sulla barra.
  ///
  /// La lista si legge da lì e non si riscrive qui: due file che dicono quali
  /// dischi esistono finirebbero per non dire la stessa cosa.
  static final double barbellStepKg = kPlatesKg.last * 2;

  /// Quanti chili aggiungere. **Nullo quando i chili non sono la leva**:
  /// elastici, corpo libero e sbarra progrediscono in un altro modo, e
  /// inventare un numero lì sarebbe peggio che dire come stanno le cose.
  final double? kg;

  /// L'attrezzo che ha deciso il gradino, per poterlo nominare.
  final Equipment? tool;

  /// Perché quel gradino, o perché non c'è. Sempre presente: un numero senza
  /// la sua ragione qui non serve a niente.
  final String reason;

  bool get isMeasurable => kg != null;

  /// Come si scrive: «+2 kg».
  String get label =>
      kg == null ? 'nessun gradino in chili' : '+${formatKg(kg!)} kg';

  /// Il gradino di un singolo attrezzo.
  ///
  /// È uno `switch` sull'enum e non una mappa apposta: quando qualcuno
  /// aggiungerà una voce a [Equipment], l'analizzatore chiederà anche il suo
  /// gradino invece di lasciarla cadere in un ramo di default che risponde a
  /// caso.
  static LoadStep forTool(Equipment tool) => switch (tool) {
    Equipment.manubri => const LoadStep._(
      kg: dumbbellStepKg,
      tool: Equipment.manubri,
      reason:
          'I manubri salgono di 2 kg per volta: quello è il gradino, e '
          'in mezzo non c\'è niente da poter caricare.',
    ),
    Equipment.bilanciere => LoadStep._(
      kg: barbellStepKg,
      tool: Equipment.bilanciere,
      reason:
          'Il bilanciere sale di una coppia di dischi da '
          '${formatPlateKg(kPlatesKg.last)} kg, cioè '
          '${formatKg(barbellStepKg)} kg sulla barra.',
    ),
    Equipment.kettlebell => const LoadStep._(
      kg: kettlebellStepKg,
      tool: Equipment.kettlebell,
      reason:
          'I kettlebell vanno di 4 in 4: è un salto grosso, guarda le '
          'prime ripetizioni prima di darlo per buono.',
    ),
    Equipment.elasticiAdAnello => const LoadStep._(
      tool: Equipment.elasticiAdAnello,
      reason:
          'L\'elastico non si misura in chili: si sale passando '
          'all\'anello più duro, o accorciandolo salendoci sopra.',
    ),
    Equipment.elasticiAncorabili => const LoadStep._(
      tool: Equipment.elasticiAncorabili,
      reason:
          'L\'elastico non si misura in chili: si sale con la banda più '
          'dura, o allontanandosi di un passo dall\'ancoraggio.',
    ),
    Equipment.sbarraTrazioni => const LoadStep._(
      tool: Equipment.sbarraTrazioni,
      reason:
          'Alla sbarra il carico è il tuo corpo: si sale di ripetizioni, '
          'con una variante più dura o appendendo un peso alla cintura.',
    ),
    Equipment.corpoLibero => const LoadStep._(
      tool: Equipment.corpoLibero,
      reason:
          'A corpo libero non ci sono chili da aggiungere: si sale di '
          'ripetizioni o si passa a una variante più difficile.',
    ),
    // Panca e tappetino reggono il corpo, non il carico: capitano nella lista
    // degli attrezzi di un esercizio (una panca inclinata con i manubri li
    // chiede tutti e due) ma non hanno un gradino da dare.
    Equipment.pancaRegolabile => const LoadStep._(
      tool: Equipment.pancaRegolabile,
      reason:
          'La panca regge il corpo, non il carico: il gradino lo dà '
          'l\'attrezzo che hai in mano.',
    ),
    Equipment.tappetino => const LoadStep._(
      tool: Equipment.tappetino,
      reason:
          'Il tappetino non porta carico: il gradino lo dà l\'attrezzo '
          'che hai in mano.',
    ),
  };

  /// Il gradino più fine fra gli attrezzi con cui l'esercizio si può fare.
  ///
  /// [tools] sono gli attrezzi che l'esercizio ammette (un goblet squat lo
  /// regge un manubrio o un kettlebell, indifferentemente), [owned] quelli
  /// che Marco ha dichiarato. Si sceglie il più fine perché è quello che
  /// consente il salto più piccolo: con manubri e kettlebell in casa, un
  /// goblet sale di 2 kg — basta prendere in mano l'altro attrezzo.
  static LoadStep smallestFor({
    required Set<Equipment> tools,
    Set<Equipment> owned = const <Equipment>{},
  }) {
    if (tools.isEmpty) {
      return const LoadStep._(
        reason:
            'Non so con che attrezzo si fa questo esercizio, e senza '
            'l\'attrezzo non so di quanto sale.',
      );
    }
    // **Il silenzio non è un no.** Un profilo che non ha ancora dichiarato
    // niente non è un profilo senza attrezzi: è la stessa regola di
    // `TrainingProfile.hasDeclaredEquipment`, e senza di lei la prima
    // proposta della vita dell'app direbbe sempre «non hai l'attrezzo».
    final usable = owned.isEmpty ? tools : tools.where(owned.contains).toSet();
    if (usable.isEmpty) {
      return const LoadStep._(
        reason:
            'Nessuno degli attrezzi di questo esercizio è fra quelli che '
            'hai dichiarato.',
      );
    }

    // Si scorre l'enum e non l'insieme: due chiamate con gli stessi attrezzi
    // devono dare lo stesso gradino, e l'ordine di iterazione di un Set non
    // lo garantisce (è la ragione per cui anche `Equipment.encode` fa così).
    LoadStep? finest;
    LoadStep? withoutStep;
    for (final tool in Equipment.values) {
      if (!usable.contains(tool)) {
        continue;
      }
      final step = forTool(tool);
      final kg = step.kg;
      if (kg == null) {
        withoutStep ??= step;
        continue;
      }
      if (finest == null || kg < finest.kg!) {
        finest = step;
      }
    }
    return finest ?? withoutStep!;
  }
}

/// Cosa fare la prossima volta.
enum ProgressionVerdict {
  /// L'intervallo è pieno: si propone il gradino.
  salire(label: 'Sali di un gradino'),

  /// In cima ma senza margine: stesso carico ancora una volta.
  consolidare(label: 'Ripeti questo carico'),

  /// L'intervallo non è ancora pieno: sono le ripetizioni a dover salire.
  restare(label: 'Continua così'),

  /// L'intervallo è pieno ma i chili non sono la leva di questo esercizio.
  senzaGradino(label: 'Qui non si sale di chili'),

  /// Non ci sono i dati per dire niente. **Non è «va tutto bene»**: è
  /// un'altra cosa, e va scritta come tale.
  nonSoDire(label: 'Non lo so dire');

  const ProgressionVerdict({required this.label});

  final String label;
}

/// Il verdetto sulla prossima sessione, con tutto quello che l'ha prodotto.
@immutable
class LoadProgressionAdvice {
  const LoadProgressionAdvice({
    required this.verdict,
    required this.reason,
    required this.countedSets,
    required this.allSetsAtTop,
    required this.marginDeclared,
    this.range,
    this.step,
    this.currentKg,
    this.proposedKg,
    this.proposedReps,
    this.hardestRpe,
    this.declarations = const [],
  });

  final ProgressionVerdict verdict;

  /// La frase da leggere. C'è sempre, anche quando non si propone niente:
  /// «non salgo» senza il perché è esattamente il consiglio che Marco già si
  /// dà da solo.
  final String reason;

  /// Quante serie di lavoro sono finite nel conto. Le altre sono in
  /// [declarations], una per ragione.
  final int countedSets;

  final bool allSetsAtTop;

  /// Vero quando lo sforzo percepito c'era su almeno una serie contata. Se è
  /// falso la proposta guarda solo le ripetizioni, e [declarations] lo dice.
  final bool marginDeclared;

  final RepRange? range;
  final LoadStep? step;

  /// Il carico da cui si parte: il più LEGGERO fra le serie contate, perché
  /// un solo numero deve reggere anche l'ultima.
  final double? currentKg;

  /// Il carico proposto. Valorizzato solo con [ProgressionVerdict.salire].
  final double? proposedKg;

  /// Le ripetizioni da cui ripartire col carico nuovo: il fondo
  /// dell'intervallo.
  final int? proposedReps;

  /// L'RPE della serie più dura fra quelle contate, quando c'è.
  final int? hardestRpe;

  /// Cosa è rimasto fuori dal conto e con che assunzioni si è calcolato. Una
  /// riga per cosa, perché un dato escluso in silenzio è un dato inventato.
  final List<String> declarations;

  bool get isProposal => verdict == ProgressionVerdict.salire;

  bool get hasDeclarations => declarations.isNotEmpty;
}

/// Il motore della doppia progressione.
abstract final class LoadProgression {
  /// Il tetto dell'RPE oltre il quale il margine non c'è più.
  ///
  /// La scala della colonna è quella dei chili in canna: 10 vuol dire zero
  /// ripetizioni rimaste, 9 ne lascia una. **Il veto scatta solo a 10**, e
  /// non a 9: nella doppia progressione l'ultima serie in cima all'intervallo
  /// è quasi sempre l'ultima serie dura della vita di quel carico, e chiedere
  /// che sia anche comoda vorrebbe dire non salire mai.
  static const int marginRpeCeiling = 9;

  /// Quante serie servono quando la scheda non dice quante ne prescrive.
  ///
  /// «In tutte le serie» con una serie sola non significa niente: una singola
  /// salita in cima è la giornata buona, non il carico diventato leggero.
  static const int minimumSetsWithoutPrescription = 2;

  /// Di quante ripetizioni si può superare il tetto prima che un gradino
  /// solo diventi sospetto. Sopra questa soglia il carico non è «pronto a
  /// salire», è chiaramente troppo leggero, e la cosa va detta.
  static const int wellAboveTopReps = 3;

  /// Cosa proporre per la prossima sessione di questo esercizio.
  ///
  /// [sets] sono le serie dell'ULTIMA sessione in cui l'esercizio compare,
  /// non lo storico intero: la doppia progressione guarda la seduta appena
  /// fatta, e il resto è già raccontato dai record. Chi chiama non deve
  /// passargli un blocco di riscaldamento o di defaticamento — lì non c'è
  /// niente da far progredire.
  ///
  /// [range] è l'intervallo della riga di scheda ([RepRange.resolve]); nullo
  /// significa numero fisso, e la progressione lo dichiara invece di
  /// inventarsi una banda.
  ///
  /// [tools] sono gli attrezzi con cui l'esercizio si fa e [owned] quelli che
  /// Marco ha: insieme danno il gradino vero (vedi [LoadStep.smallestFor]).
  ///
  /// [prescribedSets] è quante serie la scheda chiede. Quando manca si ricade
  /// su [minimumSetsWithoutPrescription], e si dichiara.
  static LoadProgressionAdvice advise({
    required List<WorkoutSet> sets,
    required RepRange? range,
    Set<Equipment> tools = const <Equipment>{},
    Set<Equipment> owned = const <Equipment>{},
    int? prescribedSets,
  }) {
    final declarations = <String>[];
    var warmupSets = 0;
    var unfinishedSets = 0;
    var setsWithoutReps = 0;
    final counted = <WorkoutSet>[];

    for (final set in sets) {
      // Le serie di avvicinamento non dicono niente sul carico di lavoro: il
      // loro compito è scaldare, e sono leggere apposta.
      if (set.isWarmup) {
        warmupSets++;
        continue;
      }
      // Una serie prescritta e mai spuntata non è successa. Contarla come
      // riuscita farebbe salire il carico su una seduta interrotta.
      if (!set.completed) {
        unfinishedSets++;
        continue;
      }
      if (set.reps case final reps? when reps > 0) {
        counted.add(set);
      } else {
        setsWithoutReps++;
      }
    }

    // «Fuori dal conto» davanti e il numero dopo, così la frase regge sia con
    // una serie sia con tre: «1 serie non spuntate» sarebbe italiano storto.
    if (warmupSets > 0) {
      declarations.add('Fuori dal conto: $warmupSets serie di riscaldamento.');
    }
    if (unfinishedSets > 0) {
      declarations.add('Fuori dal conto: $unfinishedSets serie non spuntate.');
    }
    if (setsWithoutReps > 0) {
      declarations.add(
        'Fuori dal conto: $setsWithoutReps serie senza ripetizioni segnate.',
      );
    }

    if (range == null) {
      return LoadProgressionAdvice(
        verdict: ProgressionVerdict.nonSoDire,
        reason:
            'Questa riga della scheda ha un numero fisso di ripetizioni, non '
            'un intervallo: senza un «8-12» non c\'è un momento in cui il '
            'carico deve salire.',
        countedSets: counted.length,
        allSetsAtTop: false,
        marginDeclared: false,
        declarations: List.unmodifiable(declarations),
      );
    }

    if (counted.isEmpty) {
      return LoadProgressionAdvice(
        verdict: ProgressionVerdict.nonSoDire,
        reason:
            'Nell\'ultima sessione non c\'è nessuna serie di lavoro da '
            'leggere su questo esercizio.',
        range: range,
        countedSets: 0,
        allSetsAtTop: false,
        marginDeclared: false,
        declarations: List.unmodifiable(declarations),
      );
    }

    // Il margine è quello della serie più DURA: se una sola è finita a
    // cedimento, il carico ha già trovato il suo limite anche se le altre
    // sono andate lisce.
    int? hardestRpe;
    var setsWithRpe = 0;
    for (final set in counted) {
      if (set.rpe case final rpe?) {
        setsWithRpe++;
        if (hardestRpe == null || rpe > hardestRpe) {
          hardestRpe = rpe;
        }
      }
    }
    final marginDeclared = hardestRpe != null;

    // Uno zero o un negativo valgono come «non lo so»: `presc_sets` sul
    // database sta fra 1 e 50, quindi un valore fuori scala è un chiamante
    // distratto — e con `requiredSets` a zero basterebbe una serie qualsiasi
    // per far salire il carico.
    final prescribed = prescribedSets != null && prescribedSets >= 1
        ? prescribedSets
        : null;
    final requiredSets = prescribed ?? minimumSetsWithoutPrescription;
    if (prescribed == null) {
      declarations.add(
        'La scheda non dice quante serie: ho preteso che fossero almeno '
        '$minimumSetsWithoutPrescription.',
      );
    }

    LoadProgressionAdvice stay(String reason) => LoadProgressionAdvice(
      verdict: ProgressionVerdict.restare,
      reason: reason,
      range: range,
      countedSets: counted.length,
      allSetsAtTop: false,
      marginDeclared: marginDeclared,
      hardestRpe: hardestRpe,
      declarations: List.unmodifiable(declarations),
    );

    if (counted.length < requiredSets) {
      return stay(
        'Serie di lavoro chiuse: ${counted.length} su $requiredSets. Il '
        'gradino si propone su una seduta intera, non su mezza.',
      );
    }

    final atTop = counted.where((set) => range.isAtTop(set.reps!)).length;
    if (atTop < counted.length) {
      final shortest = counted
          .map((set) => set.reps!)
          .reduce((a, b) => a < b ? a : b);
      return stay(
        'In cima a ${range.label} ci sono arrivate $atTop serie su '
        '${counted.length}, e la più corta si è fermata a $shortest. Finché '
        'non ci arrivano tutte il carico resta questo: a salire sono le '
        'ripetizioni.',
      );
    }

    if (setsWithRpe == 0) {
      // Dichiarare invece di tacere, e proporre lo stesso. Lo sforzo
      // percepito è facoltativo e nei dati veri manca spesso (vedi
      // `session_effort.dart`: 17 sessioni su 29): una regola che senza RPE
      // non propone niente resterebbe spenta quasi sempre, e uno strumento
      // muto ha la faccia rassicurante di uno che dice «va bene così».
      declarations.add(
        'Lo sforzo percepito non c\'era su nessuna serie: la proposta guarda '
        'solo le ripetizioni.',
      );
    } else if (setsWithRpe < counted.length) {
      declarations.add(
        'Lo sforzo percepito c\'era su $setsWithRpe serie di '
        '${counted.length}: il margine è quello che dicono loro.',
      );
    }

    if (hardestRpe != null && hardestRpe > marginRpeCeiling) {
      return LoadProgressionAdvice(
        verdict: ProgressionVerdict.consolidare,
        reason:
            'Tutte le serie in cima a ${range.label}, ma la più dura è '
            'finita a cedimento (sforzo $hardestRpe su 10): margine zero. '
            'Rifai questa seduta con lo stesso carico — il gradino si '
            'propone quando in canna resta almeno una ripetizione.',
        range: range,
        countedSets: counted.length,
        allSetsAtTop: true,
        marginDeclared: true,
        hardestRpe: hardestRpe,
        declarations: List.unmodifiable(declarations),
      );
    }

    final step = LoadStep.smallestFor(tools: tools, owned: owned);
    if (!step.isMeasurable) {
      return LoadProgressionAdvice(
        verdict: ProgressionVerdict.senzaGradino,
        reason:
            'Tutte le serie in cima a ${range.label}. ${step.reason} '
            'L\'intervallo però è pieno: qualcosa deve cambiare.',
        range: range,
        step: step,
        countedSets: counted.length,
        allSetsAtTop: true,
        marginDeclared: marginDeclared,
        hardestRpe: hardestRpe,
        declarations: List.unmodifiable(declarations),
      );
    }

    final weights = <double>[
      for (final set in counted)
        if (set.weightKg case final kg? when kg > 0) kg,
    ];
    if (weights.isEmpty) {
      return LoadProgressionAdvice(
        verdict: ProgressionVerdict.nonSoDire,
        reason:
            'Tutte le serie in cima a ${range.label}, ma senza il carico '
            'segnato non so da che numero far partire il gradino.',
        range: range,
        step: step,
        countedSets: counted.length,
        allSetsAtTop: true,
        marginDeclared: marginDeclared,
        hardestRpe: hardestRpe,
        declarations: List.unmodifiable(declarations),
      );
    }
    if (weights.length < counted.length) {
      declarations.add(
        '${counted.length - weights.length} serie senza carico segnato: il '
        'numero di partenza viene dalle altre.',
      );
    }

    // Il più leggero, non la media né l'ultimo: la scheda porta UN numero, e
    // quel numero deve reggere anche la serie in cui Marco ha calato.
    final lightest = weights.reduce((a, b) => a < b ? a : b);
    final heaviest = weights.reduce((a, b) => a > b ? a : b);
    if (heaviest - lightest > 0.001) {
      declarations.add(
        'Le serie non avevano lo stesso carico (da ${formatKg(lightest)} a '
        '${formatKg(heaviest)} kg): parto dal più leggero.',
      );
    }

    final shortest = counted
        .map((set) => set.reps!)
        .reduce((a, b) => a < b ? a : b);
    final overshoot = shortest - range.max;
    if (overshoot >= wellAboveTopReps) {
      declarations.add(
        'Anche la serie più corta ha superato il tetto di $overshoot '
        'ripetizioni: un gradino solo potrebbe non bastare.',
      );
    }

    final proposedKg = _roundKg(lightest + step.kg!);
    return LoadProgressionAdvice(
      verdict: ProgressionVerdict.salire,
      reason:
          'Tutte e ${counted.length} le serie in cima a ${range.label}: la '
          'prossima volta prova ${formatKg(proposedKg)} kg e riparti da '
          '${range.min} ripetizioni.',
      range: range,
      step: step,
      countedSets: counted.length,
      allSetsAtTop: true,
      marginDeclared: marginDeclared,
      hardestRpe: hardestRpe,
      currentKg: lightest,
      proposedKg: proposedKg,
      proposedReps: range.min,
      declarations: List.unmodifiable(declarations),
    );
  }

  /// Due decimali, perché `18 + 2.5` in virgola mobile sa produrre
  /// `20.500000000000004` e quel numero finirebbe scritto su una scheda.
  static double _roundKg(double value) => (value * 100).roundToDouble() / 100;
}

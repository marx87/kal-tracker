/// Il moltiplicatore di attività ricavato dagli allenamenti veri, invece che
/// scelto col dito da una tendina di cinque voci.
///
/// `ActivityLevel` è una tabella: Marco sceglie «Attivo» e il TDEE ci crede
/// per sempre, anche la settimana in cui si è allenato una volta sola. Qui il
/// numero si ricostruisce: **NEAT di base + calorie vere degli allenamenti
/// diviso il basale**, dove le calorie vere sono quelle che
/// `estimateKcal` calcola già su ogni sessione e che finora non entravano da
/// nessuna parte nel consumo giornaliero.
///
/// Due cose che questo file NON fa, di proposito:
///
/// 1. non si fida delle sessioni senza `muscleGroupSnapshot`. Lì
///    `estimateKcal` ripiega su 5,0 MET, che contro i 6,0 delle gambe e gli
///    8,0 del cardio è un errore del 20-40% sulle calorie di quella sessione.
///    Una settimana con anche una sola sessione così viene buttata intera, e
///    se non ne restano abbastanza si resta sul dichiarato **dicendo perché**;
/// 2. non applica niente. Produce una domanda — «le tue ultime tre settimane
///    dicono 1,48 invece di 1,55, vuoi aggiornare?» — e aspetta Marco.
library;

import 'dart:math' as math;

import 'package:kal_tracker/features/goal/domain/tdee.dart';

/// Una sessione allenata, ridotta ai tre fatti che servono qui.
///
/// Si costruisce a monte, nel repository degli allenamenti: `kcal` è il
/// risultato di `estimateKcal` e `muscleGroupsComplete` quello di
/// `hasCompleteMuscleGroupSnapshots`. L'area Obiettivo non conosce
/// `Workout` e non deve: qui arriva un numero e la sua affidabilità, non una
/// sessione da rileggere.
class TrainingSessionKcal {
  const TrainingSessionKcal({
    required this.endedAt,
    required this.kcal,
    required this.muscleGroupsComplete,
  });

  /// Quando è finita: è la data con cui la sessione cade in una settimana o
  /// nell'altra.
  final DateTime endedAt;

  /// Le calorie stimate della sessione.
  final double kcal;

  /// Vero quando ogni esercizio che conta portava il suo gruppo muscolare.
  /// Falso significa che dentro `kcal` c'è almeno un 5,0 MET di ripiego.
  final bool muscleGroupsComplete;

  /// Un valore negativo o non finito qui dentro è un difetto a monte, non un
  /// allenamento leggero: si tratta come uno snapshot mancante, cioè si butta
  /// la settimana invece di lasciarlo entrare nella media.
  bool get isTrustworthy => muscleGroupsComplete && kcal.isFinite && kcal >= 0;
}

/// Perché il derivato non si può usare. Non è una lista di errori: è quello
/// che la spiegazione deve dire a Marco al posto del numero.
enum DerivedMultiplierRefusal {
  /// Senza massa magra non c'è basale, e senza basale non c'è niente da
  /// dividere.
  noBasalMetabolicRate,

  /// La finestra guarda più indietro di quanto ci siano dati: le settimane
  /// prima del primo allenamento registrato sono vuote perché l'app non
  /// c'era, non perché Marco stesse fermo.
  notEnoughHistory,

  /// Troppe settimane buttate per snapshot incompleti.
  missingMuscleGroups,

  /// Finestra pulita ma quasi vuota: da due sessioni in tre settimane non si
  /// ricava un'abitudine.
  notEnoughSessions,

  /// Il numero è uscito fuori scala. Quasi sempre è un allenamento lasciato
  /// aperto, non un metabolismo da professionista.
  implausible,
}

/// Cosa dicono gli allenamenti, e cosa se ne fa: una domanda.
class ActivityMultiplierProposal {
  const ActivityMultiplierProposal({
    required this.declared,
    required this.neat,
    required this.computed,
    required this.refusal,
    required this.weeksInWindow,
    required this.weeksUsed,
    required this.weeksDiscardedForMissingGroups,
    required this.sessionsUsed,
    required this.averageWeeklyTrainingKcal,
  });

  /// Il moltiplicatore attualmente in uso: quello che Marco ha scelto.
  final ActivityLevel declared;

  /// La quota di movimento che non è allenamento.
  final double neat;

  /// Il numero uscito dal calcolo. Resta valorizzato anche quando viene
  /// rifiutato, perché la spiegazione di un rifiuto per fuori scala deve
  /// poter mostrare quanto era fuori scala.
  final double? computed;

  /// Nullo quando il derivato è utilizzabile.
  final DerivedMultiplierRefusal? refusal;

  /// Quante settimane guarda la finestra.
  final int weeksInWindow;

  /// Quante ne sono entrate nella media.
  final int weeksUsed;

  /// Quante sono state buttate perché almeno una sessione non era
  /// affidabile.
  ///
  /// Va mostrato, non solo contato: buttare settimane sposta la media. Se le
  /// sessioni senza gruppo muscolare fossero sistematicamente quelle delle
  /// gambe, il derivato verrebbe da un mese più leggero di quello vero, e
  /// senza questo numero sembrerebbe comunque una misura pulita.
  final int weeksDiscardedForMissingGroups;

  /// Quante sessioni ci sono dietro il numero.
  final int sessionsUsed;

  /// Media delle calorie di allenamento per settimana usata.
  final double averageWeeklyTrainingKcal;

  /// Il numero da proporre. Nullo quando c'è un rifiuto: così non esiste
  /// nessuna strada per applicare un derivato che non ci si fida.
  double? get proposedMultiplier => refusal == null ? computed : null;

  /// Si propone solo se la differenza si sente. Sotto [minimumGap] il TDEE
  /// cambia di meno di cento calorie al giorno sul basale di Marco: dentro il
  /// rumore della misura, e chiedere di aggiornare per quello vuol dire
  /// insegnare a rispondere «no» senza leggere.
  bool get shouldPropose {
    final derived = proposedMultiplier;
    if (derived == null) {
      return false;
    }
    return (derived - declared.multiplier).abs() >= minimumGap;
  }

  /// Sotto questa differenza il derivato conferma il dichiarato e si tace.
  static const double minimumGap = 0.05;

  /// La domanda da fare a Marco. Nulla quando non c'è niente da chiedere:
  /// l'app propone, non applica, e non insiste.
  String? get question {
    final derived = proposedMultiplier;
    if (derived == null || !shouldPropose) {
      return null;
    }
    return 'Le tue ultime $weeksUsed settimane dicono ${_n(derived)} invece '
        'di ${_n(declared.multiplier)} — vuoi aggiornare?';
  }

  /// Da dove viene il numero, o perché non c'è. Stessa regola di
  /// `TdeeEstimate.explanation`: quando un dato resta fuori dal calcolo, si
  /// dice quale e perché.
  String get explanation => switch (refusal) {
    DerivedMultiplierRefusal.noBasalMetabolicRate =>
      'Resta il moltiplicatore che hai scelto (${_n(declared.multiplier)}): '
          'senza una pesata completa non ho il metabolismo basale da cui '
          'partire.',
    DerivedMultiplierRefusal.notEnoughHistory =>
      'Resta il moltiplicatore che hai scelto (${_n(declared.multiplier)}): '
          'mi servono ${DerivedActivityMultiplier.minimumWeeks} settimane '
          'intere di allenamenti registrati e non ci sono ancora tutte.',
    DerivedMultiplierRefusal.missingMuscleGroups =>
      'Resta il moltiplicatore che hai scelto (${_n(declared.multiplier)}): '
          'su $weeksInWindow settimane ne ho dovute buttare $_discardedCount, '
          'dentro c\'erano sessioni senza gruppo muscolare — e lì le calorie '
          'escono da un 5,0 MET di ripiego che sbaglia del 20-40% su gambe e '
          'cardio.',
    DerivedMultiplierRefusal.notEnoughSessions =>
      'Resta il moltiplicatore che hai scelto (${_n(declared.multiplier)}): '
          'in $weeksInWindow settimane trovo $sessionsUsed allenamenti, e da '
          'così pochi non si ricava un\'abitudine.',
    DerivedMultiplierRefusal.implausible =>
      'Resta il moltiplicatore che hai scelto (${_n(declared.multiplier)}): '
          'dagli allenamenti verrebbe $_outOfScaleValue, che non è un '
          'metabolismo ma quasi sempre una sessione lasciata aperta.',
    null => _derivedExplanation(),
  };

  String _derivedExplanation() {
    final buffer = StringBuffer(
      'Ricavato dalle tue ultime $weeksUsed settimane: ${_n(neat)} di '
      'movimento quotidiano più le calorie vere di $sessionsUsed '
      'allenamenti (${averageWeeklyTrainingKcal.round()} kcal a settimana).',
    );
    if (weeksDiscardedForMissingGroups > 0) {
      buffer.write(
        ' E $_discardedPhrase: dentro c\'erano sessioni senza '
        'gruppo muscolare.',
      );
    }
    if (!shouldPropose) {
      buffer.write(
        ' È lo stesso numero che hai scelto: non c\'è niente da cambiare.',
      );
    }
    return buffer.toString();
  }

  /// Un numero che è arrivato all'infinito non si stampa: «Infinity» in
  /// mezzo a una frase italiana è peggio del non dirlo.
  String get _outOfScaleValue =>
      computed == null ? 'un numero fuori scala' : _n(computed!);

  /// «una» invece di «1»: il conteggio finisce dentro una frase, non dentro
  /// una tabella.
  String get _discardedCount => weeksDiscardedForMissingGroups == 1
      ? 'una'
      : '$weeksDiscardedForMissingGroups';

  String get _discardedPhrase => weeksDiscardedForMissingGroups == 1
      ? 'un\'altra settimana è rimasta fuori'
      : 'altre $weeksDiscardedForMissingGroups settimane sono rimaste fuori';
}

/// **Il moltiplicatore derivato.**
///
/// `moltiplicatore = NEAT + (kcal medie di allenamento a settimana / 7) /
/// basale`.
///
/// Il `/ 7` non è un dettaglio: il moltiplicatore moltiplica un consumo
/// **giornaliero**, quindi le calorie della settimana vanno spalmate sui
/// sette giorni. Spalmarle così — invece di caricarle sul giorno in cui ci si
/// è allenati — è anche il motivo per cui **le calorie bruciate non si
/// mangiano**: entrano nel consumo medio da cui si calcola l'obiettivo, non
/// come un bonus da riaccreditare la sera dell'allenamento.
abstract final class DerivedActivityMultiplier {
  /// Il NEAT di chi sta seduto tutto il giorno: è il pavimento, non una
  /// stima cauta.
  static const double neatFloor = 1.2;

  /// Il NEAT di chi cammina davvero. Oltre questo non si sale senza dati:
  /// tutto il resto del movimento è allenamento, e l'allenamento lo
  /// misuriamo a parte.
  static const double neatCeiling = 1.3;

  /// Le due soglie fra cui il NEAT scorre. Cinquemila passi sono la giornata
  /// da ufficio con la macchina sotto casa; diecimila sono quelli che il
  /// pavimento non spiega più.
  static const double stepsAtNeatFloor = 5000;
  static const double stepsAtNeatCeiling = 10000;

  /// Tre settimane. Una sola dice quasi niente: basta un'influenza o un
  /// deload e il numero si sposta di più di quanto si sposti il metabolismo
  /// in un anno.
  static const int minimumWeeks = 3;

  /// Meno di così, nella finestra, non è un allenamento rado: è un periodo in
  /// cui l'app non è stata usata. Il derivato scenderebbe al NEAT di base per
  /// un motivo che col metabolismo non c'entra.
  static const int minimumSessions = 3;

  /// Il NEAT di base a partire dai passi medi, quando ci sono.
  ///
  /// Senza passi si prende il pavimento: inventare il movimento che non si è
  /// misurato è esattamente il difetto della tendina a cinque voci che questo
  /// file esiste per superare.
  static double neatBaseline(double? averageDailySteps) {
    final steps = averageDailySteps;
    if (steps == null || !steps.isFinite || steps <= stepsAtNeatFloor) {
      return neatFloor;
    }
    if (steps >= stepsAtNeatCeiling) {
      return neatCeiling;
    }
    final progress =
        (steps - stepsAtNeatFloor) / (stepsAtNeatCeiling - stepsAtNeatFloor);
    return neatFloor + (neatCeiling - neatFloor) * progress;
  }

  /// Guarda le ultime settimane e prepara la domanda.
  ///
  /// [now] è esplicito perché le finestre sono di sette giorni esatti a
  /// ritroso da qui: nessuna settimana parziale entra nella media, e i test
  /// non dipendono da che giorno è oggi.
  ///
  /// [historyStartsAt] è il primo giorno in cui esistono dati. Le finestre
  /// che iniziano prima non contano come settimane di riposo: sono settimane
  /// in cui non stavamo guardando, e contarle come zero allenamenti
  /// abbasserebbe il moltiplicatore di chi ha appena installato l'app.
  static ActivityMultiplierProposal propose({
    required double basalMetabolicRate,
    required ActivityLevel declared,
    required List<TrainingSessionKcal> sessions,
    required DateTime now,
    double? averageDailySteps,
    DateTime? historyStartsAt,
    int lookbackWeeks = minimumWeeks,
  }) {
    final weeks = math.max(lookbackWeeks, minimumWeeks);
    final neat = neatBaseline(averageDailySteps);

    // Quante settimane si stanno davvero guardando: parte dalla finestra
    // richiesta e si accorcia se i dati non arrivano fin lì. È il numero che
    // compare nelle spiegazioni, perché «2 settimane su 6» sarebbe una
    // frazione inventata quando le altre quattro non esistono.
    var examinedWeeks = weeks;

    ActivityMultiplierProposal refuse(
      DerivedMultiplierRefusal refusal, {
      double? computed,
      int weeksUsed = 0,
      int weeksDiscarded = 0,
      int sessionsUsed = 0,
      double averageWeeklyKcal = 0,
    }) => ActivityMultiplierProposal(
      declared: declared,
      neat: neat,
      computed: computed,
      refusal: refusal,
      weeksInWindow: examinedWeeks,
      weeksUsed: weeksUsed,
      weeksDiscardedForMissingGroups: weeksDiscarded,
      sessionsUsed: sessionsUsed,
      averageWeeklyTrainingKcal: averageWeeklyKcal,
    );

    if (!basalMetabolicRate.isFinite || basalMetabolicRate <= 0) {
      return refuse(DerivedMultiplierRefusal.noBasalMetabolicRate);
    }

    final windowStart = now.subtract(Duration(days: 7 * weeks));
    final buckets = List.generate(weeks, (_) => <TrainingSessionKcal>[]);
    for (final session in sessions) {
      if (!session.endedAt.isAfter(windowStart)) {
        continue;
      }
      // Una sessione con data futura è un orologio sbagliato, non un
      // allenamento: sta fuori come quelle troppo vecchie.
      if (session.endedAt.isAfter(now)) {
        continue;
      }
      final index = now.difference(session.endedAt).inDays ~/ 7;
      if (index >= weeks) {
        continue;
      }
      buckets[index].add(session);
    }

    if (historyStartsAt != null) {
      examinedWeeks = _weeksCoveredBy(
        now: now,
        historyStartsAt: historyStartsAt,
        cap: weeks,
      );
    }
    if (examinedWeeks < minimumWeeks) {
      return refuse(DerivedMultiplierRefusal.notEnoughHistory);
    }

    var weeksUsed = 0;
    var weeksDiscarded = 0;
    var sessionsUsed = 0;
    var trainingKcal = 0.0;
    for (var index = 0; index < examinedWeeks; index++) {
      final bucket = buckets[index];
      // Basta una sessione di cui non ci si fida per buttare la settimana:
      // dentro una media a sette giorni una sessione sbagliata del 40% non si
      // diluisce, si nasconde.
      if (bucket.any((session) => !session.isTrustworthy)) {
        weeksDiscarded++;
        continue;
      }
      // Una settimana senza allenamenti resta invece dentro: è una settimana
      // vera in cui non ci si è allenati, e toglierla farebbe la media di
      // qualcuno che si allena sempre.
      weeksUsed++;
      sessionsUsed += bucket.length;
      for (final session in bucket) {
        trainingKcal += session.kcal;
      }
    }

    // Le settimane esaminate sono almeno tre e ognuna è finita da una parte o
    // dall'altra: se non ne restano tre pulite, la causa sono per forza
    // quelle buttate.
    if (weeksUsed < minimumWeeks) {
      return refuse(
        DerivedMultiplierRefusal.missingMuscleGroups,
        weeksUsed: weeksUsed,
        weeksDiscarded: weeksDiscarded,
        sessionsUsed: sessionsUsed,
      );
    }

    final averageWeeklyKcal = trainingKcal / weeksUsed;
    if (sessionsUsed < minimumSessions) {
      return refuse(
        DerivedMultiplierRefusal.notEnoughSessions,
        weeksUsed: weeksUsed,
        weeksDiscarded: weeksDiscarded,
        sessionsUsed: sessionsUsed,
        averageWeeklyKcal: averageWeeklyKcal,
      );
    }

    final computed = neat + (averageWeeklyKcal / 7) / basalMetabolicRate;
    // Stesso tetto della misura del TDEE: oltre due volte e mezzo il basale
    // non è un metabolismo, è un dato sbagliato.
    if (!computed.isFinite || computed > AdaptiveTdee.maxMultiplierOfBmr) {
      return refuse(
        DerivedMultiplierRefusal.implausible,
        computed: computed.isFinite ? computed : null,
        weeksUsed: weeksUsed,
        weeksDiscarded: weeksDiscarded,
        sessionsUsed: sessionsUsed,
        averageWeeklyKcal: averageWeeklyKcal,
      );
    }

    return ActivityMultiplierProposal(
      declared: declared,
      neat: neat,
      computed: computed,
      refusal: null,
      weeksInWindow: examinedWeeks,
      weeksUsed: weeksUsed,
      weeksDiscardedForMissingGroups: weeksDiscarded,
      sessionsUsed: sessionsUsed,
      averageWeeklyTrainingKcal: averageWeeklyKcal,
    );
  }

  static int _weeksCoveredBy({
    required DateTime now,
    required DateTime historyStartsAt,
    required int cap,
  }) {
    final days = now.difference(historyStartsAt).inDays;
    if (days <= 0) {
      return 0;
    }
    return math.min(days ~/ 7, cap);
  }
}

String _n(double value) => value.toStringAsFixed(2).replaceAll('.', ',');

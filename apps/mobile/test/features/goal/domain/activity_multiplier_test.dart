import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/goal/domain/activity_multiplier.dart';
import 'package:kal_tracker/features/goal/domain/body_composition.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';

import '../marco.dart';

/// Il momento da cui contare le settimane. Fisso, perché le finestre sono
/// sette giorni a ritroso da «adesso» e un test che dipende da che giorno è
/// oggi fallisce di lunedì e passa di martedì.
final DateTime now = DateTime(2026, 8, 7, 20);

final double marcoBasal = BodyComposition.basalMetabolicRate(marcoFatFreeMass);

/// Il MET medio con cui i test costruiscono le sessioni: è il valore di
/// ripiego di `estimateKcal`, cioè quello che esce da una seduta mista.
const double testMet = 5.0;

/// Da quota netta a calorie lorde: `MET / (MET − 1)`.
///
/// Serve ai test che partono dal moltiplicatore che vogliono ottenere e
/// devono risalire alle calorie che il repository consegnerebbe — che sono
/// sempre lorde, perché `estimateKcal` non toglie niente.
double grossFor(double netKcal) => netKcal * testMet / (testMet - 1);

/// Una sessione pulita finita [daysAgo] giorni fa. [kcal] è LORDA, come esce
/// da `estimateKcal`.
TrainingSessionKcal session(int daysAgo, double kcal, {double met = testMet}) =>
    TrainingSessionKcal(
      endedAt: now.subtract(Duration(days: daysAgo)),
      kcal: kcal,
      averageMet: met,
      muscleGroupsComplete: true,
    );

/// La stessa sessione, ma senza gruppo muscolare: dentro le sue kcal c'è il
/// 5,0 MET di ripiego.
TrainingSessionKcal blindSession(int daysAgo, double kcal) =>
    TrainingSessionKcal(
      endedAt: now.subtract(Duration(days: daysAgo)),
      kcal: kcal,
      averageMet: testMet,
      muscleGroupsComplete: false,
    );

/// Tre settimane da quattro allenamenti: la routine normale di Marco.
List<TrainingSessionKcal> threeCleanWeeks({double kcal = 600}) => [
  for (var week = 0; week < 3; week++)
    for (final offset in const [1, 3, 4, 6]) session(week * 7 + offset, kcal),
];

/// Un anno fa: lo storico lungo è il caso normale, e i test che parlano
/// d'altro non devono ripeterlo. Quelli che parlano proprio dello storico
/// corto passano la loro data.
final DateTime longHistory = now.subtract(const Duration(days: 365));

ActivityMultiplierProposal proposeFor(
  List<TrainingSessionKcal> sessions, {
  ActivityLevel declared = ActivityLevel.moderate,
  double? averageDailySteps,
  DateTime? historyStartsAt,
  int lookbackWeeks = 3,
  double? basal,
}) => DerivedActivityMultiplier.propose(
  basalMetabolicRate: basal ?? marcoBasal,
  declared: declared,
  sessions: sessions,
  now: now,
  averageDailySteps: averageDailySteps,
  historyStartsAt: historyStartsAt ?? longHistory,
  lookbackWeeks: lookbackWeeks,
);

void main() {
  group('il NEAT di base', () {
    test('senza passi resta il pavimento: non si inventa movimento', () {
      expect(DerivedActivityMultiplier.neatBaseline(null), 1.2);
    });

    test('cinquemila passi sono ancora la giornata da ufficio', () {
      expect(DerivedActivityMultiplier.neatBaseline(5000), 1.2);
    });

    test('da diecimila in su non si sale oltre 1,3', () {
      expect(DerivedActivityMultiplier.neatBaseline(10000), 1.3);
      expect(DerivedActivityMultiplier.neatBaseline(25000), 1.3);
    });

    test('in mezzo scorre: 7500 passi stanno a metà', () {
      expect(DerivedActivityMultiplier.neatBaseline(7500), closeTo(1.25, 1e-9));
    });
  });

  group('il numero derivato', () {
    test('è NEAT più le kcal settimanali spalmate su sette giorni', () {
      final proposal = proposeFor(threeCleanWeeks());

      // 4 sessioni × 600 kcal lorde = 2400 a settimana; al netto del riposo
      // sono 1920, cioè 274,29 al giorno.
      expect(proposal.averageWeeklyGrossTrainingKcal, closeTo(2400, 0.01));
      expect(proposal.averageWeeklyTrainingKcal, closeTo(1920, 0.01));
      expect(
        proposal.proposedMultiplier,
        closeTo(1.2 + (1920 / 7) / marcoBasal, 1e-9),
      );
      expect(proposal.weeksUsed, 3);
      expect(proposal.sessionsUsed, 12);
      expect(proposal.refusal, isNull);
    });

    test('le kcal della settimana NON si caricano sul giorno di palestra', () {
      // Stesso monte calorie, distribuito in due sessioni lunghe invece che
      // in quattro corte: il moltiplicatore non cambia, perché moltiplica un
      // consumo medio giornaliero e non il giorno in cui ci si è allenati.
      final quattro = proposeFor(threeCleanWeeks());
      final due = proposeFor([
        for (var week = 0; week < 3; week++)
          for (final offset in const [1, 4]) session(week * 7 + offset, 1200),
      ]);

      expect(
        due.proposedMultiplier,
        closeTo(quattro.proposedMultiplier!, 1e-9),
      );
    });

    test('un NEAT più alto alza il moltiplicatore di quel tanto', () {
      final fermo = proposeFor(threeCleanWeeks());
      final camminatore = proposeFor(
        threeCleanWeeks(),
        averageDailySteps: 12000,
      );

      expect(
        camminatore.proposedMultiplier! - fermo.proposedMultiplier!,
        closeTo(0.1, 1e-9),
      );
    });

    test('una settimana di riposo resta dentro la media', () {
      // Togliere la settimana vuota farebbe la media di qualcun altro: di uno
      // che si allena sempre. Il deload è parte del programma, non un buco.
      final conRiposo = proposeFor([
        for (final offset in const [1, 3, 4, 6]) session(offset, 600),
        // la settimana centrale è vuota
        for (final offset in const [15, 17, 18, 20]) session(offset, 600),
      ]);

      expect(conRiposo.weeksUsed, 3);
      expect(conRiposo.sessionsUsed, 8);
      expect(conRiposo.averageWeeklyGrossTrainingKcal, closeTo(1600, 0.01));
      expect(conRiposo.averageWeeklyTrainingKcal, closeTo(1280, 0.01));
    });

    test('le sessioni fuori finestra e quelle nel futuro non entrano', () {
      final proposal = proposeFor([
        ...threeCleanWeeks(),
        session(30, 5000), // un mese fa: fuori dalle tre settimane
        TrainingSessionKcal(
          endedAt: now.add(const Duration(days: 2)),
          kcal: 5000,
          averageMet: testMet,
          muscleGroupsComplete: true,
        ),
      ]);

      expect(proposal.sessionsUsed, 12);
      expect(proposal.averageWeeklyGrossTrainingKcal, closeTo(2400, 0.01));
    });
  });

  group('le calorie lorde non si sommano al NEAT', () {
    test('entra la quota netta, perché il riposo il NEAT lo contava già', () {
      // A 5,0 MET un quinto delle calorie della seduta è il metabolismo che
      // ci sarebbe stato comunque, seduti sul divano: quelle ore stanno
      // dentro il NEAT, che copre la giornata intera.
      final proposal = proposeFor(threeCleanWeeks());

      expect(proposal.averageWeeklyGrossTrainingKcal, closeTo(2400, 0.01));
      expect(proposal.averageWeeklyTrainingKcal, closeTo(1920, 0.01));
    });

    test('il doppio conteggio bastava da solo a far comparire la domanda', () {
      // 480 kcal a settimana di differenza, cioè ~69 al giorno: +0,036 di
      // moltiplicatore sul basale di Marco. minimumGap è 0,05, quindi lo
      // scarto valeva quasi una proposta intera.
      final proposal = proposeFor(threeCleanWeeks());
      final lordo = 1.2 + (2400 / 7) / marcoBasal;

      expect(lordo - proposal.proposedMultiplier!, closeTo(0.0358, 0.0005));
      expect(
        lordo - proposal.proposedMultiplier!,
        greaterThan(ActivityMultiplierProposal.minimumGap / 2),
      );
    });

    test('un MET più alto lascia dentro una fetta più grande', () {
      // Stesse calorie lorde a 8,0 MET (cardio): l'ora è stata più intensa,
      // quindi la quota di riposo da togliere pesa meno — 7/8 invece di 4/5.
      final cardio = proposeFor([
        for (var week = 0; week < 3; week++)
          for (final offset in const [1, 3, 4, 6])
            session(week * 7 + offset, 600, met: 8),
      ]);

      expect(cardio.averageWeeklyGrossTrainingKcal, closeTo(2400, 0.01));
      expect(cardio.averageWeeklyTrainingKcal, closeTo(2400 * 7 / 8, 0.01));
    });

    test('la spiegazione dice quante calorie sono state tolte', () {
      final proposal = proposeFor(threeCleanWeeks());

      expect(proposal.explanation, contains('1920 kcal a settimana'));
      expect(proposal.explanation, contains('tolte le 480 di riposo'));
    });

    test('un MET sotto il riposo non è un allenamento: butta la settimana', () {
      // Sotto l'unità la quota netta sarebbe negativa. È un difetto a monte,
      // e si tratta come uno snapshot mancante invece di sottrarre calorie.
      final proposal = proposeFor(
        threeCleanWeeks()..add(session(2, 900, met: 0.5)),
      );

      expect(proposal.refusal, DerivedMultiplierRefusal.missingMuscleGroups);
      expect(proposal.weeksDiscardedForMissingGroups, 1);
    });
  });

  group('lo snapshot mancante blocca il derivato', () {
    test('una sola sessione cieca butta la settimana intera', () {
      final sessions = threeCleanWeeks()
        ..add(blindSession(2, 900)); // seconda sessione della settimana 0

      final proposal = proposeFor(sessions);

      expect(proposal.proposedMultiplier, isNull);
      expect(proposal.refusal, DerivedMultiplierRefusal.missingMuscleGroups);
      expect(proposal.weeksDiscardedForMissingGroups, 1);
      expect(proposal.weeksUsed, 2);
    });

    test('e la spiegazione dice perché, con l\'errore del ripiego', () {
      final proposal = proposeFor(threeCleanWeeks()..add(blindSession(2, 900)));

      expect(
        proposal.explanation,
        contains('su 3 settimane ne ho dovute buttare una'),
      );
      expect(proposal.explanation, contains('senza gruppo muscolare'));
      expect(proposal.explanation, contains('5,0'));
      expect(proposal.explanation, contains('20-40%'));
      expect(proposal.question, isNull);
    });

    test('con la finestra più lunga bastano tre settimane pulite', () {
      // Sei settimane guardate, la più recente sporca: ne restano cinque
      // pulite e il derivato si può fare lo stesso.
      final proposal = proposeFor([
        for (var week = 0; week < 6; week++)
          for (final offset in const [1, 3, 4, 6])
            session(week * 7 + offset, 600),
        blindSession(2, 900),
      ], lookbackWeeks: 6);

      expect(proposal.refusal, isNull);
      expect(proposal.weeksUsed, 5);
      expect(proposal.weeksDiscardedForMissingGroups, 1);
      expect(
        proposal.explanation,
        contains('un\'altra settimana è rimasta fuori'),
      );
    });

    test('kcal non finite valgono quanto uno snapshot mancante', () {
      final proposal = proposeFor(
        threeCleanWeeks()..add(
          TrainingSessionKcal(
            endedAt: now.subtract(const Duration(days: 2)),
            kcal: double.nan,
            averageMet: testMet,
            muscleGroupsComplete: true,
          ),
        ),
      );

      expect(proposal.refusal, DerivedMultiplierRefusal.missingMuscleGroups);
    });
  });

  group('quando il derivato non si fa', () {
    test('senza basale non c\'è niente da dividere', () {
      final proposal = proposeFor(threeCleanWeeks(), basal: 0);

      expect(proposal.refusal, DerivedMultiplierRefusal.noBasalMetabolicRate);
      expect(proposal.explanation, contains('pesata completa'));
    });

    test('due settimane di app installata non fanno una finestra', () {
      final proposal = proposeFor(
        threeCleanWeeks(),
        historyStartsAt: now.subtract(const Duration(days: 15)),
      );

      expect(proposal.refusal, DerivedMultiplierRefusal.notEnoughHistory);
      expect(proposal.explanation, contains('3 settimane intere'));
    });

    test('tre sedute su un\'app installata ieri non abbassano niente', () {
      // Il caso che il rifiuto esisteva per fermare: sei giorni di storico e
      // tre sedute vere. Contando tre settimane, due sarebbero vuote perché
      // l'app non c'era — e la proposta direbbe di SCENDERE.
      final proposal = proposeFor([
        for (final offset in const [1, 3, 5]) session(offset, 600),
      ], historyStartsAt: now.subtract(const Duration(days: 6)));

      expect(proposal.refusal, DerivedMultiplierRefusal.notEnoughHistory);
      expect(proposal.proposedMultiplier, isNull);
      expect(proposal.weeksInWindow, 0);
    });

    test('la finestra si ferma dove finisce lo storico', () {
      // Sei settimane chieste, quattro di dati: se ne guardano quattro. Le
      // altre due non sono settimane di riposo, sono settimane non osservate.
      final proposal = proposeFor(
        [
          for (var week = 0; week < 6; week++)
            for (final offset in const [1, 3, 4, 6])
              session(week * 7 + offset, 600),
        ],
        historyStartsAt: now.subtract(const Duration(days: 29)),
        lookbackWeeks: 6,
      );

      expect(proposal.refusal, isNull);
      expect(proposal.weeksInWindow, 4);
      expect(proposal.weeksUsed, 4);
      expect(proposal.sessionsUsed, 16);
    });

    test('tre settimane vuote non sono tre settimane sedentarie', () {
      // Se bastasse il silenzio, il derivato scenderebbe al NEAT di base per
      // un motivo che col metabolismo non c'entra: l'app non è stata usata.
      final proposal = proposeFor(const []);

      expect(proposal.refusal, DerivedMultiplierRefusal.notEnoughSessions);
      expect(proposal.proposedMultiplier, isNull);
      expect(proposal.explanation, contains('0 allenamenti'));
    });

    test('un allenamento lasciato aperto non diventa un metabolismo', () {
      final proposal = proposeFor([
        for (var week = 0; week < 3; week++)
          for (final offset in const [1, 3, 4])
            session(week * 7 + offset, 12000),
      ]);

      expect(proposal.refusal, DerivedMultiplierRefusal.implausible);
      expect(proposal.proposedMultiplier, isNull);
      expect(proposal.computed, greaterThan(AdaptiveTdee.maxMultiplierOfBmr));
      expect(proposal.explanation, contains('lasciata aperta'));
    });

    test('ogni rifiuto ripete il dichiarato che resta in vigore', () {
      for (final proposal in [
        proposeFor(threeCleanWeeks(), basal: 0),
        proposeFor(const []),
        proposeFor(threeCleanWeeks()..add(blindSession(2, 900))),
      ]) {
        expect(proposal.explanation, contains('1,55'));
        expect(proposal.question, isNull);
      }
    });
  });

  group('si propone, non si applica', () {
    test('la domanda è quella dell\'esempio, con i due numeri', () {
      // Serve un derivato ≈ 1,48 con basale 1918: 0,28 × 1918 × 7 kcal NETTE
      // a settimana, che a 5,0 MET sono 1568 lorde per sessione con tre
      // sessioni a settimana.
      final target = grossFor(0.28 * marcoBasal * 7 / 3);
      final proposal = proposeFor([
        for (var week = 0; week < 3; week++)
          for (final offset in const [1, 3, 5])
            session(week * 7 + offset, target),
      ]);

      expect(proposal.shouldPropose, isTrue);
      expect(proposal.proposedMultiplier, closeTo(1.48, 0.005));
      expect(
        proposal.question,
        'Le tue ultime 3 settimane dicono 1,48 invece di 1,55 — vuoi '
        'aggiornare?',
      );
    });

    test('sotto i cinque centesimi non si chiede niente', () {
      // 1,55 dichiarato contro un derivato che gli sta a ridosso: chiedere
      // «vuoi aggiornare?» per meno di cento calorie insegna a rispondere no
      // senza leggere.
      final target = grossFor(
        (ActivityLevel.moderate.multiplier - 1.2 - 0.01) * marcoBasal * 7 / 3,
      );
      final proposal = proposeFor([
        for (var week = 0; week < 3; week++)
          for (final offset in const [1, 3, 5])
            session(week * 7 + offset, target),
      ]);

      expect(proposal.proposedMultiplier, isNotNull);
      expect(proposal.shouldPropose, isFalse);
      expect(proposal.question, isNull);
      expect(proposal.explanation, contains('niente da cambiare'));
    });

    test('la spiegazione del derivato dice settimane, sessioni e kcal', () {
      final proposal = proposeFor(threeCleanWeeks());

      expect(proposal.explanation, contains('ultime 3 settimane'));
      expect(proposal.explanation, contains('12 allenamenti'));
      expect(proposal.explanation, contains('1920 kcal a settimana'));
      expect(proposal.explanation, contains('1,20'));
    });

    test('proporre non cambia il TDEE: quello resta sul dichiarato', () {
      final proposal = proposeFor([
        for (var week = 0; week < 3; week++)
          for (final offset in const [1, 3, 5])
            session(week * 7 + offset, grossFor(0.28 * marcoBasal * 7 / 3)),
      ]);

      // Il TDEE calcolato senza passare il derivato è ancora quello di prima:
      // la proposta esiste, ma finché Marco non dice sì non tocca niente.
      final prima = AdaptiveTdee.resolve(
        fatFreeMassKg: marcoFatFreeMass,
        activity: ActivityLevel.moderate,
      );

      expect(proposal.shouldPropose, isTrue);
      expect(prima.kcal, closeTo(marcoBasal * 1.55, 0.01));
      expect(prima.multiplierWasDerived, isFalse);

      // E dopo il sì, passandolo esplicitamente, cambia.
      final dopo = AdaptiveTdee.resolve(
        fatFreeMassKg: marcoFatFreeMass,
        activity: ActivityLevel.moderate,
        derivedMultiplier: proposal.proposedMultiplier,
      );

      expect(
        dopo.kcal,
        closeTo(marcoBasal * proposal.proposedMultiplier!, 0.01),
      );
      expect(dopo.multiplierWasDerived, isTrue);
    });
  });

  group('quello che resta scritto', () {
    test('il dichiarato e il derivato accettato fanno il giro completo', () {
      const settings = ActivitySettings(
        declared: ActivityLevel.high,
        acceptedMultiplier: 1.48,
      );

      expect(ActivitySettings.fromJson(settings.toJson()), settings);
    });

    test('un file troncato torna al dichiarato invece di lanciare', () {
      final settings = ActivitySettings.fromJson(const {});

      expect(settings.declared, ActivityLevel.moderate);
      expect(settings.acceptedMultiplier, isNull);
    });

    test('un derivato fuori forbice non si rilegge', () {
      // Il TDEE lo ignorerebbe comunque: tenerlo scritto vorrebbe dire un
      // campo valorizzato che non fa niente, e nessun modo di accorgersene.
      final settings = ActivitySettings.fromJson(const {
        'declared': 'light',
        'accepted_multiplier': 3.4,
      });

      expect(settings.declared, ActivityLevel.light);
      expect(settings.acceptedMultiplier, isNull);
    });

    test('scegliere un livello a mano toglie il derivato accettato', () {
      const accettato = ActivitySettings(
        declared: ActivityLevel.moderate,
        acceptedMultiplier: 1.48,
      );

      expect(
        accettato.withDeclared(ActivityLevel.light).acceptedMultiplier,
        isNull,
      );
      // E toglierlo lascia in piedi la scelta, che era rimasta lì sotto.
      expect(
        accettato.withoutAcceptedMultiplier().declared,
        ActivityLevel.moderate,
      );
    });
  });
}

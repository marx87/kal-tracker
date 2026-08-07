import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';
import 'package:kal_tracker/features/workouts/domain/load_progression.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// La doppia progressione.
///
/// I casi che contano sono tre, e sono quelli che hanno motivato il file: la
/// seduta piena deve produrre un NUMERO da provare la prossima volta, quella
/// a metà non deve produrne nessuno, e il gradino proposto deve essere un
/// peso che esiste davvero in casa di Marco.

WorkoutSet _set({
  double? kg = 20,
  int? reps = 12,
  int? rpe,
  bool completed = true,
  bool isWarmup = false,
}) => WorkoutSet(
  weightKg: kg,
  reps: reps,
  rpe: rpe,
  completed: completed,
  isWarmup: isWarmup,
);

const _range = RepRange(min: 8, max: 12);

LoadProgressionAdvice _advise(
  List<WorkoutSet> sets, {
  RepRange? range = _range,
  Set<Equipment> tools = const {Equipment.manubri},
  Set<Equipment> owned = const <Equipment>{},
  int? prescribedSets = 3,
}) => LoadProgression.advise(
  sets: sets,
  range: range,
  tools: tools,
  owned: owned,
  prescribedSets: prescribedSets,
);

void main() {
  group('l\'intervallo', () {
    test('un numero fisso non è un intervallo', () {
      expect(RepRange.resolve(min: 8, max: 12)?.label, '8-12');
      expect(RepRange.resolve(min: 12, max: 12), isNull);
      expect(RepRange.resolve(min: 12, max: 8), isNull);
      expect(RepRange.resolve(min: null, max: 12), isNull);
      expect(RepRange.resolve(min: 8, max: null), isNull);
      expect(RepRange.resolve(min: 0, max: 12), isNull);
    });

    test('gli estremi sono dentro, e oltre il tetto si è comunque in cima', () {
      expect(_range.contains(8), isTrue);
      expect(_range.contains(12), isTrue);
      expect(_range.contains(7), isFalse);
      expect(_range.contains(13), isFalse);
      expect(_range.isAtTop(11), isFalse);
      expect(_range.isAtTop(12), isTrue);
      expect(_range.isAtTop(14), isTrue);
    });

    test('il suggerimento allarga solo verso l\'alto', () {
      // Il punto della decisione: `10` diventa `10-12`, non `8-12`. Un
      // intervallo aperto verso il basso renderebbe la seduta più facile di
      // quella che la scheda chiedeva.
      final suggested = RepRange.suggestedFor(10);

      expect(suggested?.min, 10);
      expect(suggested?.max, 12);
      expect(RepRange.suggestedFor(null), isNull);
      expect(RepRange.suggestedFor(0), isNull);
    });
  });

  group('il gradino', () {
    test('con i manubri è 2 kg, non una percentuale', () {
      final step = LoadStep.smallestFor(tools: const {Equipment.manubri});

      expect(step.kg, 2);
      expect(step.isMeasurable, isTrue);
      expect(step.tool, Equipment.manubri);
      expect(step.label, '+2 kg');
    });

    test('col bilanciere è la coppia di dischi più piccola', () {
      final step = LoadStep.smallestFor(tools: const {Equipment.bilanciere});

      // 1,25 kg per lato: sulla barra fanno 2,5.
      expect(step.kg, 2.5);
      expect(step.label, '+2.5 kg');
    });

    test('il kettlebell sale di 4 e lo dice', () {
      final step = LoadStep.smallestFor(tools: const {Equipment.kettlebell});

      expect(step.kg, 4);
      expect(step.reason, contains('4 in 4'));
    });

    test('fra due attrezzi possibili vince il gradino più fine', () {
      // Il goblet squat lo regge un manubrio o un kettlebell: con tutti e due
      // in casa il salto piccolo esiste, basta prendere l'altro attrezzo.
      final step = LoadStep.smallestFor(
        tools: const {Equipment.manubri, Equipment.kettlebell},
      );

      expect(step.kg, 2);
      expect(step.tool, Equipment.manubri);
    });

    test('si guarda solo l\'attrezzatura dichiarata', () {
      final step = LoadStep.smallestFor(
        tools: const {Equipment.manubri, Equipment.kettlebell},
        owned: const {Equipment.kettlebell},
      );

      expect(step.kg, 4);
      expect(step.tool, Equipment.kettlebell);
    });

    test(
      'il silenzio non è un no: senza dichiarazioni si usa l\'esercizio',
      () {
        final step = LoadStep.smallestFor(tools: const {Equipment.bilanciere});

        expect(step.kg, 2.5);
      },
    );

    test('un attrezzo che non si ha non dà nessun gradino', () {
      final step = LoadStep.smallestFor(
        tools: const {Equipment.bilanciere},
        owned: const {Equipment.manubri, Equipment.tappetino},
      );

      expect(step.isMeasurable, isFalse);
      expect(step.reason, contains('hai dichiarato'));
    });

    test('elastici e corpo libero non hanno chili da aggiungere', () {
      for (final tool in const [
        Equipment.elasticiAdAnello,
        Equipment.elasticiAncorabili,
        Equipment.corpoLibero,
        Equipment.sbarraTrazioni,
        Equipment.pancaRegolabile,
        Equipment.tappetino,
      ]) {
        expect(LoadStep.forTool(tool).isMeasurable, isFalse, reason: '$tool');
      }
    });

    test('ogni attrezzo dell\'enum ha una ragione da leggere', () {
      for (final tool in Equipment.values) {
        expect(LoadStep.forTool(tool).reason, isNotEmpty, reason: '$tool');
      }
    });

    test('la panca non è l\'attrezzo che porta il carico', () {
      // Una panca inclinata con i manubri chiede tutti e due gli attrezzi: il
      // gradino lo deve dare il manubrio.
      final step = LoadStep.smallestFor(
        tools: const {Equipment.manubri, Equipment.pancaRegolabile},
      );

      expect(step.tool, Equipment.manubri);
      expect(step.kg, 2);
    });
  });

  group('quando si sale', () {
    test(
      'tutte le serie in cima: propone carico e ripetizioni di ripartenza',
      () {
        final advice = _advise([
          _set(kg: 20, reps: 12, rpe: 8),
          _set(kg: 20, reps: 12, rpe: 8),
          _set(kg: 20, reps: 12, rpe: 9),
        ]);

        expect(advice.verdict, ProgressionVerdict.salire);
        expect(advice.isProposal, isTrue);
        expect(advice.currentKg, 20);
        expect(advice.proposedKg, 22);
        // Le ripetizioni tornano in fondo: è la seconda metà della doppia
        // progressione.
        expect(advice.proposedReps, 8);
        expect(advice.allSetsAtTop, isTrue);
        expect(advice.reason, contains('22 kg'));
        expect(advice.reason, contains('8 ripetizioni'));
      },
    );

    test('col bilanciere il gradino è 2,5 e il numero resta caricabile', () {
      final advice = _advise(
        [
          _set(kg: 47.5, reps: 12, rpe: 8),
          _set(kg: 47.5, reps: 12, rpe: 8),
          _set(kg: 47.5, reps: 12, rpe: 8),
        ],
        tools: const {Equipment.bilanciere},
      );

      expect(advice.proposedKg, 50);
    });

    test('nove su dieci è ancora margine: una ripetizione in canna basta', () {
      final advice = _advise([
        _set(reps: 12, rpe: 9),
        _set(reps: 12, rpe: 9),
        _set(reps: 12, rpe: 9),
      ]);

      expect(advice.verdict, ProgressionVerdict.salire);
      expect(advice.hardestRpe, 9);
      expect(advice.marginDeclared, isTrue);
    });

    test('oltre il tetto sale lo stesso, dicendo che forse non basta', () {
      final advice = _advise([
        _set(reps: 16, rpe: 7),
        _set(reps: 15, rpe: 7),
        _set(reps: 15, rpe: 8),
      ]);

      expect(advice.verdict, ProgressionVerdict.salire);
      expect(
        advice.declarations,
        contains(startsWith('Anche la serie più corta ha superato il tetto')),
      );
    });

    test('il carico di partenza è il più leggero, e si dichiara', () {
      // Ultima serie calata di due chili: un numero solo deve reggere anche
      // quella.
      final advice = _advise([
        _set(kg: 22, reps: 12, rpe: 8),
        _set(kg: 22, reps: 12, rpe: 8),
        _set(kg: 20, reps: 12, rpe: 9),
      ]);

      expect(advice.currentKg, 20);
      expect(advice.proposedKg, 22);
      expect(
        advice.declarations,
        contains(startsWith('Le serie non avevano lo stesso carico')),
      );
    });

    test('la virgola mobile non finisce sulla scheda', () {
      final advice = _advise(
        [
          _set(kg: 18, reps: 12, rpe: 8),
          _set(kg: 18, reps: 12, rpe: 8),
          _set(kg: 18, reps: 12, rpe: 8),
        ],
        tools: const {Equipment.bilanciere},
      );

      expect(advice.proposedKg, 20.5);
    });
  });

  group('quando non si sale', () {
    test('una serie sotto il tetto tiene fermo il carico', () {
      final advice = _advise([
        _set(reps: 12, rpe: 8),
        _set(reps: 12, rpe: 8),
        _set(reps: 10, rpe: 9),
      ]);

      expect(advice.verdict, ProgressionVerdict.restare);
      expect(advice.allSetsAtTop, isFalse);
      expect(advice.proposedKg, isNull);
      expect(advice.reason, contains('2 serie su 3'));
      expect(advice.reason, contains('si è fermata a 10'));
    });

    test('mezza seduta non è una seduta: tre serie prescritte, due fatte', () {
      final advice = _advise([
        _set(reps: 12, rpe: 8),
        _set(reps: 12, rpe: 8),
        _set(reps: 12, completed: false),
      ]);

      expect(advice.verdict, ProgressionVerdict.restare);
      expect(advice.countedSets, 2);
      expect(advice.reason, contains('2 su 3'));
      expect(
        advice.declarations,
        contains('Fuori dal conto: 1 serie non spuntate.'),
      );
    });

    test('in cima ma a cedimento: si consolida invece di salire', () {
      final advice = _advise([
        _set(reps: 12, rpe: 8),
        _set(reps: 12, rpe: 9),
        _set(reps: 12, rpe: 10),
      ]);

      expect(advice.verdict, ProgressionVerdict.consolidare);
      expect(advice.allSetsAtTop, isTrue);
      expect(advice.hardestRpe, 10);
      expect(advice.proposedKg, isNull);
      expect(advice.reason, contains('margine zero'));
    });

    test('una serie sola non è «tutte le serie» quando la scheda tace', () {
      final advice = _advise([_set(reps: 12, rpe: 8)], prescribedSets: null);

      expect(advice.verdict, ProgressionVerdict.restare);
      expect(
        advice.declarations,
        contains(startsWith('La scheda non dice quante serie')),
      );
    });

    test('una serie sola basta se è la scheda a prescriverne una', () {
      final advice = _advise([_set(reps: 12, rpe: 8)], prescribedSets: 1);

      expect(advice.verdict, ProgressionVerdict.salire);
    });

    test('zero serie prescritte valgono come «non lo so»', () {
      // Con la soglia a zero una serie qualsiasi farebbe salire il carico.
      final advice = _advise([_set(reps: 12, rpe: 8)], prescribedSets: 0);

      expect(advice.verdict, ProgressionVerdict.restare);
      expect(
        advice.declarations,
        contains(startsWith('La scheda non dice quante serie')),
      );
    });
  });

  group('quando non si sa dire', () {
    test('senza intervallo la doppia progressione non parte', () {
      final advice = _advise([
        _set(reps: 10, rpe: 8),
        _set(reps: 10, rpe: 8),
        _set(reps: 10, rpe: 8),
      ], range: null);

      expect(advice.verdict, ProgressionVerdict.nonSoDire);
      expect(advice.reason, contains('numero fisso'));
      expect(advice.isProposal, isFalse);
    });

    test('«non lo so dire» non è «va tutto bene»', () {
      final advice = _advise(const []);

      expect(advice.verdict, ProgressionVerdict.nonSoDire);
      expect(advice.countedSets, 0);
      expect(advice.proposedKg, isNull);
      for (final verdict in ProgressionVerdict.values) {
        expect(verdict.label, isNotEmpty);
      }
    });

    test('senza carico segnato non c\'è un numero da cui partire', () {
      final advice = _advise([
        _set(kg: null, reps: 12, rpe: 8),
        _set(kg: null, reps: 12, rpe: 8),
        _set(kg: null, reps: 12, rpe: 8),
      ]);

      expect(advice.verdict, ProgressionVerdict.nonSoDire);
      expect(advice.allSetsAtTop, isTrue);
      expect(advice.reason, contains('senza il carico segnato'));
    });

    test('a corpo libero l\'intervallo pieno chiede un\'altra leva', () {
      final advice = _advise(
        [
          _set(kg: null, reps: 12, rpe: 8),
          _set(kg: null, reps: 12, rpe: 8),
          _set(kg: null, reps: 12, rpe: 8),
        ],
        tools: const {Equipment.corpoLibero},
      );

      expect(advice.verdict, ProgressionVerdict.senzaGradino);
      expect(advice.reason, contains('variante più difficile'));
      expect(advice.step?.isMeasurable, isFalse);
    });
  });

  group('quello che resta fuori si dichiara', () {
    test('riscaldamento e serie senza ripetizioni non entrano nel conto', () {
      final advice = _advise([
        _set(kg: 10, reps: 15, isWarmup: true),
        _set(kg: 20, reps: 12, rpe: 8),
        _set(kg: 20, reps: 12, rpe: 8),
        _set(kg: 20, reps: 12, rpe: 8),
        _set(kg: 20, reps: null),
      ]);

      expect(advice.countedSets, 3);
      expect(advice.verdict, ProgressionVerdict.salire);
      expect(
        advice.declarations,
        containsAll([
          'Fuori dal conto: 1 serie di riscaldamento.',
          'Fuori dal conto: 1 serie senza ripetizioni segnate.',
        ]),
      );
    });

    test('lo sforzo percepito mancante non blocca, ma si dice', () {
      // L'RPE è facoltativo e nei dati veri manca spesso: una regola che
      // senza di lui non propone niente resterebbe muta quasi sempre.
      final advice = _advise([_set(reps: 12), _set(reps: 12), _set(reps: 12)]);

      expect(advice.verdict, ProgressionVerdict.salire);
      expect(advice.marginDeclared, isFalse);
      expect(advice.hardestRpe, isNull);
      expect(
        advice.declarations,
        contains(startsWith('Lo sforzo percepito non c\'era')),
      );
    });

    test('lo sforzo percepito parziale dichiara su quante serie c\'era', () {
      final advice = _advise([
        _set(reps: 12, rpe: 8),
        _set(reps: 12),
        _set(reps: 12),
      ]);

      expect(advice.marginDeclared, isTrue);
      expect(
        advice.declarations,
        contains(
          'Lo sforzo percepito c\'era su 1 serie di 3: il margine è '
          'quello che dicono loro.',
        ),
      );
    });

    test('una proposta senza niente da dichiarare non dichiara niente', () {
      final advice = _advise([
        _set(reps: 12, rpe: 8),
        _set(reps: 12, rpe: 8),
        _set(reps: 12, rpe: 8),
      ]);

      expect(advice.hasDeclarations, isFalse);
      expect(advice.declarations, isEmpty);
    });
  });

  group('la sessione dopo', () {
    test('il carico proposto riparte in fondo e risale l\'intervallo', () {
      // Il giro completo della doppia progressione, come lo vedrebbe Marco in
      // tre sedute: 20×12 piene → 22 kg da 8 → si risale fino a 12 → 24 kg.
      final prima = _advise([
        _set(kg: 20, reps: 12, rpe: 8),
        _set(kg: 20, reps: 12, rpe: 8),
        _set(kg: 20, reps: 12, rpe: 8),
      ]);
      expect(prima.proposedKg, 22);
      expect(prima.proposedReps, 8);

      final dopo = _advise([
        _set(kg: 22, reps: 9, rpe: 8),
        _set(kg: 22, reps: 8, rpe: 9),
        _set(kg: 22, reps: 8, rpe: 9),
      ]);
      expect(dopo.verdict, ProgressionVerdict.restare);

      final poi = _advise([
        _set(kg: 22, reps: 12, rpe: 8),
        _set(kg: 22, reps: 12, rpe: 9),
        _set(kg: 22, reps: 12, rpe: 9),
      ]);
      expect(poi.proposedKg, 24);
      expect(poi.proposedReps, 8);
    });
  });
}

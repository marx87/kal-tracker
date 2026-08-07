import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/training_profile/domain/exercise_screening.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';

/// Un esercizio del catalogo. I nomi sono quelli veri dell'export di Gym
/// Tracker: lo screening legge il nome, quindi provarlo con nomi inventati
/// proverebbe un'altra cosa.
Exercise esercizio(String name, MuscleGroup group) => Exercise(
  id: name,
  name: name,
  muscleGroup: group,
  trackingMode: ExerciseTrackingMode.weightReps,
  isPreset: true,
  source: 'gym_tracker',
  createdAt: DateTime.utc(2026, 8, 1),
);

TrainingLimitation limitazione({
  required BodyPart bodyPart,
  required LimitationSeverity severity,
  DateTime? resolvedAt,
  String? note,
}) => TrainingLimitation(
  id: '${bodyPart.storage}-${severity.name}',
  bodyPart: bodyPart,
  severity: severity,
  note: note,
  startedAt: DateTime.utc(2026, 7, 20),
  resolvedAt: resolvedAt,
);

/// La casa di Marco: manubri, elastici ad anello e un tappetino. Niente
/// gancio a cui appendere niente.
const attrezzaturaDiCasa = {
  Equipment.manubri,
  Equipment.elasticiAdAnello,
  Equipment.tappetino,
  Equipment.pancaRegolabile,
};

TrainingProfile profilo({
  Set<Equipment> equipment = attrezzaturaDiCasa,
  List<TrainingLimitation> limitations = const [],
}) => TrainingProfile(
  profileId: 'marco',
  equipment: equipment,
  limitations: limitations,
);

void main() {
  final shoulderPress = esercizio(
    'Shoulder press con manubri',
    MuscleGroup.spalle,
  );
  final pushDown = esercizio(
    'Push-down tricipiti con elastico',
    MuscleGroup.tricipiti,
  );

  group('le limitazioni', () {
    test('spalla in fastidio: la shoulder press si SEGNALA, non si toglie', () {
      // Il caso che ha fatto nascere il profilo. Un fastidio non è un divieto:
      // togliere l'esercizio sarebbe comodo per l'app e sbagliato per Marco,
      // che quella spinta la può fare più bassa.
      final esito = ExerciseScreener.screen(
        exercise: shoulderPress,
        profile: profilo(
          limitations: [
            limitazione(
              bodyPart: BodyPart.spallaDx,
              severity: LimitationSeverity.fastidio,
            ),
          ],
        ),
      );

      expect(esito.outcome, ScreeningOutcome.segnalato);
      expect(esito.isFlagged, isTrue);
      // Segnalare senza dire cosa fare al posto suo rimanderebbe il lavoro a
      // Marco: l'alternativa è parte dell'esito, non un extra.
      expect(esito.alternative, isNotNull);
      expect(esito.alternative, contains('panca inclinata'));
      expect(esito.reason, contains('spalla destra'));
      expect(esito.limitations.single.bodyPart, BodyPart.spallaDx);
    });

    test('la stessa spalla in stop la ESCLUDE', () {
      final esito = ExerciseScreener.screen(
        exercise: shoulderPress,
        profile: profilo(
          limitations: [
            limitazione(
              bodyPart: BodyPart.spallaDx,
              severity: LimitationSeverity.stop,
            ),
          ],
        ),
      );

      expect(esito.outcome, ScreeningOutcome.escluso);
      expect(esito.reason, contains('stop'));
      expect(esito.reason, contains('spalla destra'));
    });

    test('il lato non conta: una spalla destra ferma toglie una spinta che si '
        'fa con due', () {
      final esito = ExerciseScreener.screen(
        exercise: esercizio('Military press bilanciere', MuscleGroup.spalle),
        profile: profilo(
          equipment: {...attrezzaturaDiCasa, Equipment.bilanciere},
          limitations: [
            limitazione(
              bodyPart: BodyPart.spallaSx,
              severity: LimitationSeverity.stop,
            ),
          ],
        ),
      );

      expect(esito.outcome, ScreeningOutcome.escluso);
    });

    test('«dolore» esclude sull\'articolazione che fa il movimento e segnala '
        'su quella che accompagna', () {
      final curl = esercizio('Curl bicipiti con manubri', MuscleGroup.bicipiti);

      final gomito = ExerciseScreener.screen(
        exercise: curl,
        profile: profilo(
          limitations: [
            limitazione(
              bodyPart: BodyPart.gomitoDx,
              severity: LimitationSeverity.dolore,
            ),
          ],
        ),
      );
      expect(gomito.outcome, ScreeningOutcome.escluso);

      // La spalla nel curl regge, non tira: il carico si sposta cambiando
      // presa, e per questo resta una segnalazione.
      final spalla = ExerciseScreener.screen(
        exercise: curl,
        profile: profilo(
          limitations: [
            limitazione(
              bodyPart: BodyPart.spallaDx,
              severity: LimitationSeverity.dolore,
            ),
          ],
        ),
      );
      expect(spalla.outcome, ScreeningOutcome.segnalato);
      expect(spalla.alternative, isNotNull);
    });

    test('una limitazione chiusa non filtra più niente', () {
      // **Chiusa vuol dire chiusa.** Resta nello storico a spiegare perché la
      // scheda di luglio era quella, ma non toglie un esercizio in più.
      final esito = ExerciseScreener.screen(
        exercise: shoulderPress,
        profile: profilo(
          limitations: [
            limitazione(
              bodyPart: BodyPart.spallaDx,
              severity: LimitationSeverity.stop,
              resolvedAt: DateTime.utc(2026, 8, 1),
            ),
          ],
        ),
      );

      expect(esito.outcome, ScreeningOutcome.libero);
      expect(esito.reason, isNull);
      expect(esito.alternative, isNull);
    });

    test('con due limitazioni aperte vince la più grave', () {
      final esito = ExerciseScreener.screen(
        exercise: shoulderPress,
        profile: profilo(
          limitations: [
            limitazione(
              bodyPart: BodyPart.spallaDx,
              severity: LimitationSeverity.fastidio,
            ),
            limitazione(
              bodyPart: BodyPart.collo,
              severity: LimitationSeverity.stop,
            ),
          ],
        ),
      );

      expect(esito.outcome, ScreeningOutcome.escluso);
      expect(esito.reason, contains('collo'));
    });

    test('una zona che l\'esercizio non tocca non lo filtra', () {
      final esito = ExerciseScreener.screen(
        exercise: shoulderPress,
        profile: profilo(
          limitations: [
            limitazione(
              bodyPart: BodyPart.cavigliaSx,
              severity: LimitationSeverity.stop,
            ),
          ],
        ),
      );

      expect(esito.outcome, ScreeningOutcome.libero);
    });
  });

  group('l\'attrezzatura', () {
    test('il push-down tricipiti senza elastici ancorabili è ESCLUSO', () {
      // La ragione per cui l'enum distingue anelli e ancorabili: con i soli
      // anelli non c'è un punto sopra la testa, e quel movimento non esiste.
      final esito = ExerciseScreener.screen(
        exercise: pushDown,
        profile: profilo(),
      );

      expect(esito.outcome, ScreeningOutcome.escluso);
      expect(esito.missingEquipment, hasLength(1));
      expect(esito.missingEquipment.single.label, contains('ancoraggio'));
      expect(esito.reason, contains('ancoraggio'));
    });

    test('con gli elastici ancorabili lo stesso push-down è libero', () {
      final esito = ExerciseScreener.screen(
        exercise: pushDown,
        profile: profilo(
          equipment: {...attrezzaturaDiCasa, Equipment.elasticiAncorabili},
        ),
      );

      expect(esito.outcome, ScreeningOutcome.libero);
    });

    test('un profilo che non ha ancora dichiarato niente non filtra '
        'sull\'attrezzatura', () {
      // Silenzio non è un no. Trattare la lista vuota come «non ho nulla»
      // svuoterebbe il catalogo al primo avvio, prima ancora che Marco possa
      // rispondere.
      final esito = ExerciseScreener.screen(
        exercise: pushDown,
        profile: profilo(equipment: const {}),
      );

      expect(esito.outcome, ScreeningOutcome.libero);
    });

    test('quello che chiede una palestra resta fuori da una casa', () {
      final esito = ExerciseScreener.screen(
        exercise: esercizio('Lat machine presa ampia', MuscleGroup.schiena),
        profile: profilo(),
      );

      expect(esito.outcome, ScreeningOutcome.escluso);
      expect(
        esito.missingEquipment.map((requirement) => requirement.label),
        contains('un attrezzo da palestra'),
      );
    });

    test(
      'l\'attrezzo dichiarato nel nome vince sulla famiglia del movimento',
      () {
        // «Swing con manubrio» non deve chiedere anche il kettlebell solo
        // perché è uno swing: chiederebbe l'attrezzo che il nome esclude.
        final requisiti = ExerciseScreener.requirementsOf(
          esercizio('Swing con manubrio', MuscleGroup.fullbody),
        );

        expect(requisiti, hasLength(1));
        expect(requisiti.single.options, {Equipment.manubri});
      },
    );

    test('la panca è un requisito a parte, che si somma all\'attrezzo', () {
      final requisiti = ExerciseScreener.requirementsOf(
        esercizio('Panca inclinata manubri', MuscleGroup.petto),
      );

      expect(
        requisiti.map((requirement) => requirement.options),
        containsAll([
          {Equipment.manubri},
          {Equipment.pancaRegolabile},
        ]),
      );
    });

    test(
      'senza panca la panca inclinata esce, anche con i manubri in mano',
      () {
        final esito = ExerciseScreener.screen(
          exercise: esercizio('Panca inclinata manubri', MuscleGroup.petto),
          profile: profilo(equipment: {Equipment.manubri, Equipment.tappetino}),
        );

        expect(esito.outcome, ScreeningOutcome.escluso);
        expect(esito.reason, contains('panca'));
      },
    );
  });

  group('la mappa esercizio → articolazioni', () {
    test('la spinta sopra la testa carica la spalla come primaria', () {
      final joints = ExerciseScreener.jointsOf(shoulderPress);

      expect(joints[JointArea.spalla], JointRole.primaria);
      expect(joints[JointArea.gomito], JointRole.secondaria);
    });

    test('le flessioni caricano spalla e polso: sono le mani a terra', () {
      final joints = ExerciseScreener.jointsOf(
        esercizio('Flessioni (push-up)', MuscleGroup.petto),
      );

      expect(joints[JointArea.spalla], JointRole.primaria);
      expect(joints[JointArea.polso], JointRole.primaria);
    });

    test('lo squat carica ginocchio e anca, la schiena solo di rimbalzo', () {
      final joints = ExerciseScreener.jointsOf(
        esercizio('Squat a corpo libero', MuscleGroup.gambe),
      );

      expect(joints[JointArea.ginocchio], JointRole.primaria);
      expect(joints[JointArea.anca], JointRole.primaria);
      expect(joints[JointArea.lombari], JointRole.secondaria);
    });

    test('lo stacco promuove la zona lombare a primaria', () {
      // Il gruppo «gambe» da solo la darebbe secondaria: è il nome a sapere
      // che nello stacco la schiena è l'esercizio.
      final joints = ExerciseScreener.jointsOf(
        esercizio('Stacco da terra', MuscleGroup.gambe),
      );

      expect(joints[JointArea.lombari], JointRole.primaria);
    });
  });

  test('lo screening del catalogo torna un esito per ogni esercizio', () {
    final esiti = ExerciseScreener.screenAll(
      exercises: [shoulderPress, pushDown],
      profile: profilo(
        limitations: [
          limitazione(
            bodyPart: BodyPart.spallaDx,
            severity: LimitationSeverity.fastidio,
          ),
        ],
      ),
    );

    expect(esiti, hasLength(2));
    expect(esiti[shoulderPress.id]!.outcome, ScreeningOutcome.segnalato);
    expect(esiti[pushDown.id]!.outcome, ScreeningOutcome.escluso);
  });

  test('ogni esito diverso da «libero» porta con sé la sua ragione', () {
    // Quando si toglie qualcosa lo si dichiara: un catalogo che si accorcia
    // senza spiegare perché è un catalogo rotto.
    final catalogo = [
      shoulderPress,
      pushDown,
      esercizio('Curl bicipiti con manubri', MuscleGroup.bicipiti),
      esercizio('Squat a corpo libero', MuscleGroup.gambe),
      esercizio('Lat machine presa ampia', MuscleGroup.schiena),
      esercizio('Trazioni presa ampia', MuscleGroup.schiena),
    ];
    final esiti = ExerciseScreener.screenAll(
      exercises: catalogo,
      profile: profilo(
        limitations: [
          limitazione(
            bodyPart: BodyPart.spallaDx,
            severity: LimitationSeverity.fastidio,
          ),
          limitazione(
            bodyPart: BodyPart.ginocchioDx,
            severity: LimitationSeverity.dolore,
          ),
        ],
      ),
    );

    for (final esito in esiti.values) {
      if (esito.isFree) {
        continue;
      }
      expect(esito.reason, isNotNull, reason: esito.exerciseId);
      if (esito.isFlagged) {
        expect(esito.alternative, isNotNull, reason: esito.exerciseId);
      }
    }
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';

TrainingLimitation limitazione({
  required String id,
  required BodyPart bodyPart,
  required LimitationSeverity severity,
  DateTime? resolvedAt,
}) => TrainingLimitation(
  id: id,
  bodyPart: bodyPart,
  severity: severity,
  startedAt: DateTime.utc(2026, 7, 1),
  resolvedAt: resolvedAt,
);

void main() {
  group('l\'attrezzatura sulla riga', () {
    test('si rilegge com\'è stata scritta', () {
      const scelta = {
        Equipment.manubri,
        Equipment.elasticiAncorabili,
        Equipment.tappetino,
      };

      expect(Equipment.parse(Equipment.encode(scelta)), scelta);
    });

    test('l\'ordine è quello dell\'enum, non quello dei clic', () {
      // Due profili con gli stessi attrezzi devono produrre la stessa
      // stringa: altrimenti la sincronizzazione vede una modifica dove non
      // c'è, e riscrive la riga a ogni apertura della schermata.
      final primo = Equipment.encode({Equipment.tappetino, Equipment.manubri});
      final secondo = Equipment.encode({
        Equipment.manubri,
        Equipment.tappetino,
      });

      expect(primo, secondo);
      expect(primo, 'manubri,tappetino');
    });

    test(
      'un attrezzo che non conosciamo viene lasciato cadere, non tradotto',
      () {
        // Arriverebbe da una versione più nuova dell'app: inventargli un
        // corrispondente fra quelli che ci sono metterebbe in mano a Marco un
        // attrezzo che non ha.
        expect(Equipment.parse('manubri,anelli_da_soffitto,tappetino'), {
          Equipment.manubri,
          Equipment.tappetino,
        });
      },
    );

    test('la stringa vuota è un profilo che non ha ancora risposto', () {
      expect(Equipment.parse(''), isEmpty);
      expect(
        const TrainingProfile.empty('marco').hasDeclaredEquipment,
        isFalse,
      );
    });
  });

  group('i giorni preferiti', () {
    test('tornano in ordine di settimana, comunque siano stati scritti', () {
      expect(TrainingDay.parse('ven,lun,mer'), [
        TrainingDay.lun,
        TrainingDay.mer,
        TrainingDay.ven,
      ]);
      expect(TrainingDay.encode([TrainingDay.ven, TrainingDay.lun]), 'lun,ven');
    });

    test('portano con sé il numero di DateTime.weekday', () {
      expect(TrainingDay.lun.weekday, DateTime.monday);
      expect(TrainingDay.dom.weekday, DateTime.sunday);
    });
  });

  group('le limitazioni del profilo', () {
    test('solo le aperte contano, e vale la più grave', () {
      final profile = TrainingProfile(
        profileId: 'marco',
        limitations: [
          limitazione(
            id: 'a',
            bodyPart: BodyPart.spallaDx,
            severity: LimitationSeverity.fastidio,
          ),
          limitazione(
            id: 'b',
            bodyPart: BodyPart.spallaSx,
            severity: LimitationSeverity.dolore,
          ),
          limitazione(
            id: 'c',
            bodyPart: BodyPart.spallaSx,
            severity: LimitationSeverity.stop,
            resolvedAt: DateTime.utc(2026, 7, 20),
          ),
        ],
      );

      expect(profile.activeLimitations, hasLength(2));
      expect(profile.activeFor(JointArea.spalla), hasLength(2));
      // Lo `stop` c'è, ma è chiuso: non deve alzare la gravità.
      expect(profile.severityFor(JointArea.spalla), LimitationSeverity.dolore);
      expect(profile.severityFor(JointArea.ginocchio), isNull);
    });

    test('la gravità si ordina, e serve a decidere chi vince', () {
      expect(
        LimitationSeverity.stop.isAtLeast(LimitationSeverity.dolore),
        isTrue,
      );
      expect(
        LimitationSeverity.fastidio.isAtLeast(LimitationSeverity.dolore),
        isFalse,
      );
    });

    test('una zona ha un lato, un\'articolazione no', () {
      expect(BodyPart.spallaDx.area, JointArea.spalla);
      expect(BodyPart.spallaSx.area, JointArea.spalla);
      expect(BodyPart.spallaDx.side, BodySide.destro);
      expect(BodyPart.lombari.side, BodySide.centrale);
      expect(BodyPart.fromStorage('spalla_dx'), BodyPart.spallaDx);
      expect(BodyPart.fromStorage('gomito_destro'), isNull);
    });
  });

  test('nel dubbio lo scarico si chiede, non si applica', () {
    expect(DeloadPreference.fromStorage(null), DeloadPreference.suggerito);
    expect(
      DeloadPreference.fromStorage('automatico'),
      DeloadPreference.automatico,
    );
    expect(
      const TrainingProfile.empty('marco').deloadPreference,
      DeloadPreference.suggerito,
    );
  });
}

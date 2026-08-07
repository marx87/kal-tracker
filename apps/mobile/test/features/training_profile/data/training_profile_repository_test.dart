import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart'
    hide TrainingLimitation, TrainingProfile;
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/training_profile/data/training_profile_repository.dart';
import 'package:kal_tracker/features/training_profile/domain/exercise_screening.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';

void main() {
  late AppDatabase database;
  late TrainingProfileRepository repository;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = TrainingProfileRepository(database);
  });

  tearDown(() => database.close());

  Future<List<Map<String, Object?>>> outbox(String entityType) async {
    final rows = await database.select(database.syncOutbox).get();
    return rows
        .where((row) => row.entityType == entityType)
        .map(
          (row) => {
            'operation': row.operation,
            ...jsonDecode(row.payloadJson) as Map<String, Object?>,
          },
        )
        .toList(growable: false);
  }

  test(
    'il profilo che non è mai stato salvato si legge lo stesso, vuoto',
    () async {
      // La riga di `training_profiles` può mancare mentre le limitazioni ci
      // sono già: chi legge deve ricevere un profilo valido, non un null da
      // gestire in ogni schermata.
      final profile = await repository.loadProfile(profileId);

      expect(profile.equipment, isEmpty);
      expect(profile.hasDeclaredEquipment, isFalse);
      expect(profile.limitations, isEmpty);
      expect(profile.deloadPreference, DeloadPreference.suggerito);
      expect(profile.unreadableLimitations, 0);
    },
  );

  test('attrezzatura e disponibilità si salvano e si rileggono', () async {
    await repository.saveProfile(
      TrainingProfile(
        profileId: profileId,
        equipment: const {
          Equipment.manubri,
          Equipment.elasticiAncorabili,
          Equipment.tappetino,
        },
        sessionsPerWeek: 4,
        minutesPerSession: 45,
        preferredDays: const [
          TrainingDay.ven,
          TrainingDay.lun,
          TrainingDay.mer,
        ],
        deloadPreference: DeloadPreference.automatico,
      ),
    );

    final saved = await repository.loadProfile(profileId);
    expect(saved.equipment, {
      Equipment.manubri,
      Equipment.elasticiAncorabili,
      Equipment.tappetino,
    });
    expect(saved.sessionsPerWeek, 4);
    expect(saved.minutesPerSession, 45);
    expect(saved.preferredDays, [
      TrainingDay.lun,
      TrainingDay.mer,
      TrainingDay.ven,
    ]);
    expect(saved.deloadPreference, DeloadPreference.automatico);

    final righe = await outbox('training_profile');
    expect(righe, hasLength(1));
    expect(righe.single['operation'], 'upsert');
    expect(righe.single['equipment'], 'manubri,elasticiAncorabili,tappetino');
    expect(righe.single['preferred_days'], 'lun,mer,ven');
    expect(righe.single['deload_preference'], 'automatico');
  });

  test('il secondo salvataggio aggiorna la riga e conserva la data di '
      'creazione', () async {
    await repository.saveProfile(
      TrainingProfile(
        profileId: profileId,
        equipment: const {Equipment.manubri},
        sessionsPerWeek: 3,
      ),
    );
    // Si retrodata la riga a mano: senza, i due salvataggi cadrebbero nello
    // stesso secondo (drift arrotonda lì) e il test non distinguerebbe una
    // data conservata da una riscritta.
    final creazione = DateTime.utc(2026, 7, 1, 6);
    await (database.update(database.trainingProfiles)
          ..where((table) => table.profileId.equals(profileId)))
        .write(TrainingProfilesCompanion(createdAt: Value(creazione)));

    await repository.saveProfile(
      TrainingProfile(
        profileId: profileId,
        equipment: const {Equipment.manubri, Equipment.kettlebell},
        sessionsPerWeek: 5,
      ),
    );

    final saved = await repository.loadProfile(profileId);
    expect(saved.equipment, {Equipment.manubri, Equipment.kettlebell});
    expect(saved.sessionsPerWeek, 5);

    final righe = await outbox('training_profile');
    expect(righe, hasLength(2));
    // `created_at` è la data della prima risposta di Marco: riscriverla a
    // ogni salvataggio la cancellerebbe.
    expect(righe.last['created_at'], creazione.toIso8601String());
    expect(righe.last['updated_at'], isNot(creazione.toIso8601String()));
  });

  test(
    'una disponibilità impossibile si rifiuta con una frase leggibile',
    () async {
      await expectLater(
        repository.saveProfile(
          TrainingProfile(profileId: profileId, sessionsPerWeek: 20),
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        repository.saveProfile(
          TrainingProfile(profileId: profileId, minutesPerSession: 2),
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('una limitazione nasce aperta e resta aperta', () async {
    final id = await repository.addLimitation(
      profileId: profileId,
      bodyPart: BodyPart.spallaDx,
      severity: LimitationSeverity.fastidio,
      note: 'Sopra i 90° di rotazione esterna',
      startedAt: DateTime.utc(2026, 7, 28),
    );

    final profile = await repository.loadProfile(profileId);
    final limitation = profile.limitations.single;
    expect(limitation.id, id);
    expect(limitation.bodyPart, BodyPart.spallaDx);
    expect(limitation.severity, LimitationSeverity.fastidio);
    expect(limitation.note, 'Sopra i 90° di rotazione esterna');
    // Drift restituisce ora locale: si confronta l'istante, non il fuso.
    expect(limitation.startedAt.toUtc(), DateTime.utc(2026, 7, 28));
    // Nessuna scadenza automatica: si chiude quando lo dice Marco.
    expect(limitation.resolvedAt, isNull);
    expect(limitation.isActive, isTrue);

    final righe = await outbox('training_limitation');
    expect(righe.single['body_part'], 'spalla_dx');
    expect(righe.single['severity'], 'fastidio');
    expect(righe.single['resolved_at'], isNull);
  });

  test(
    'chiuderla la toglie dal filtro senza toglierla dallo storico',
    () async {
      final id = await repository.addLimitation(
        profileId: profileId,
        bodyPart: BodyPart.spallaDx,
        severity: LimitationSeverity.stop,
      );

      await repository.resolveLimitation(
        id,
        resolvedAt: DateTime.utc(2026, 8, 6),
      );

      final profile = await repository.loadProfile(profileId);
      expect(profile.limitations, hasLength(1));
      expect(profile.activeLimitations, isEmpty);
      expect(
        profile.limitations.single.resolvedAt?.toUtc(),
        DateTime.utc(2026, 8, 6),
      );

      final righe = await outbox('training_limitation');
      expect(
        righe.last['resolved_at'],
        DateTime.utc(2026, 8, 6).toIso8601String(),
      );
    },
  );

  test(
    'riaprirla è tornare alla stessa storia, non aprirne una nuova',
    () async {
      final id = await repository.addLimitation(
        profileId: profileId,
        bodyPart: BodyPart.ginocchioDx,
        severity: LimitationSeverity.dolore,
      );
      await repository.resolveLimitation(id);
      await repository.reopenLimitation(id);

      final profile = await repository.loadProfile(profileId);
      expect(profile.limitations, hasLength(1));
      expect(profile.activeLimitations.single.id, id);
    },
  );

  test('modificarla riscrive gravità e nota, non la chiusura', () async {
    final id = await repository.addLimitation(
      profileId: profileId,
      bodyPart: BodyPart.spallaDx,
      severity: LimitationSeverity.fastidio,
    );
    await repository.updateLimitation(
      id: id,
      bodyPart: BodyPart.spallaDx,
      severity: LimitationSeverity.dolore,
      note: 'Peggiorata dopo la panca di giovedì',
    );

    final limitation = (await repository.loadProfile(
      profileId,
    )).limitations.single;
    expect(limitation.severity, LimitationSeverity.dolore);
    expect(limitation.note, 'Peggiorata dopo la panca di giovedì');
    expect(limitation.resolvedAt, isNull);
  });

  test(
    'cancellarla la fa sparire, in locale e nella coda di sincronia',
    () async {
      final id = await repository.addLimitation(
        profileId: profileId,
        bodyPart: BodyPart.lombari,
        severity: LimitationSeverity.stop,
      );
      await repository.deleteLimitation(id);

      final profile = await repository.loadProfile(profileId);
      expect(profile.limitations, isEmpty);

      final righe = await outbox('training_limitation');
      expect(righe.last['operation'], 'delete');
    },
  );

  test('lo stream segue sia il profilo sia le limitazioni', () async {
    // Le due tabelle non si guardano fra loro: una limitazione può nascere
    // quando la riga del profilo non esiste ancora. Se lo stream seguisse una
    // sola delle due, la schermata resterebbe ferma.
    final letture = <TrainingProfile>[];
    final subscription = repository.watchProfile(profileId).listen(letture.add);
    await pumpEventQueue();

    await repository.saveProfile(
      TrainingProfile(
        profileId: profileId,
        equipment: const {Equipment.manubri},
      ),
    );
    await pumpEventQueue();
    final dopoIlProfilo = letture.length;

    await repository.addLimitation(
      profileId: profileId,
      bodyPart: BodyPart.spallaDx,
      severity: LimitationSeverity.stop,
    );
    await pumpEventQueue();
    await subscription.cancel();

    expect(letture.first.hasDeclaredEquipment, isFalse);
    // La scrittura sulla sola tabella delle limitazioni deve muovere lo
    // stream: è la metà che si perderebbe seguendo solo il profilo.
    expect(letture.length, greaterThan(dopoIlProfilo));
    expect(letture.last.equipment, {Equipment.manubri});
    expect(letture.last.activeLimitations, hasLength(1));
  });

  test('il profilo salvato filtra davvero il catalogo', () async {
    // La prova che le tre parti stanno insieme: quello che Marco dichiara
    // nella schermata è quello che lo screening usa.
    await repository.saveProfile(
      TrainingProfile(
        profileId: profileId,
        equipment: const {
          Equipment.manubri,
          Equipment.elasticiAdAnello,
          Equipment.tappetino,
        },
      ),
    );
    await repository.addLimitation(
      profileId: profileId,
      bodyPart: BodyPart.spallaDx,
      severity: LimitationSeverity.fastidio,
    );

    final profile = await repository.loadProfile(profileId);
    Exercise esercizio(String name, MuscleGroup group) => Exercise(
      id: name,
      name: name,
      muscleGroup: group,
      trackingMode: ExerciseTrackingMode.weightReps,
      isPreset: true,
      source: 'gym_tracker',
      createdAt: DateTime.utc(2026, 8, 1),
    );

    final esiti = ExerciseScreener.screenAll(
      exercises: [
        esercizio('Shoulder press con manubri', MuscleGroup.spalle),
        esercizio('Push-down tricipiti con elastico', MuscleGroup.tricipiti),
        esercizio('Squat a corpo libero', MuscleGroup.gambe),
      ],
      profile: profile,
    );

    expect(
      esiti['Shoulder press con manubri']!.outcome,
      ScreeningOutcome.segnalato,
    );
    expect(
      esiti['Push-down tricipiti con elastico']!.outcome,
      ScreeningOutcome.escluso,
    );
    expect(esiti['Squat a corpo libero']!.outcome, ScreeningOutcome.libero);
  });
}

import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/data/body_repository.dart';
import 'package:kal_tracker/features/body/domain/bia_formula.dart';
import 'package:kal_tracker/features/body/domain/scale_session.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  late AppDatabase database;
  late BodyRepository repository;
  late String profileId;

  final marcoBirth = DateTime.utc(1987, 9, 13);

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = BodyRepository(database);
    // Il profilo di Marco, completo: senza altezza, nascita e sesso nessuna
    // equazione BIA ha qualcosa da dire.
    await (database.update(
      database.appProfiles,
    )..where((row) => row.id.equals(profileId))).write(
      AppProfilesCompanion(
        heightCm: const Value(182),
        birthDate: Value(marcoBirth),
        sex: const Value('M'),
      ),
    );
  });

  tearDown(() => database.close());

  ScaleReading reading({
    double weightKg = 95.8,
    double? impedanceOhm = 442,
    DateTime? measuredAt,
    String rawPayloadHex = '100b15256c0101ba01f472',
  }) => ScaleReading(
    measuredAt: measuredAt ?? DateTime.utc(2026, 8, 6, 5, 12),
    weightKg: weightKg,
    deviceName: 'QN-Scale',
    rawPayloadHex: rawPayloadHex,
    impedanceOhm: impedanceOhm,
    secondaryOhm: 500,
  );

  BodyCompositionEstimate estimateFor(ScaleReading value) {
    final input = biaInputFrom(
      heightCm: 182,
      birthDate: marcoBirth,
      sexCode: 'M',
      weightKg: value.weightKg,
      impedanceOhm: value.impedanceOhm,
      measuredAt: value.measuredAt,
    )!;
    return BiaFormulas.current.estimate(input)!;
  }

  Future<LocalBodyMeasurement> single() =>
      database.select(database.bodyMeasurements).getSingle();

  Future<List<Map<String, Object?>>> outbox() async {
    final rows = await database.select(database.syncOutbox).get();
    return rows
        .where((row) => row.entityType == 'body_measurement')
        .map((row) => jsonDecode(row.payloadJson) as Map<String, Object?>)
        .toList(growable: false);
  }

  group('pesata dalla bilancia', () {
    test(
      'conserva la misura grezza, la formula che l’ha letta e la trama',
      () async {
        final value = reading();
        await repository.addScaleMeasurement(
          profileId: profileId,
          reading: value,
          composition: estimateFor(value),
        );

        final saved = await single();
        expect(saved.source, 'renpho_ble');
        expect(saved.weightKg, closeTo(95.8, 0.001));
        expect(saved.impedanceOhm, 442);
        expect(saved.hasImpedance, isTrue);
        expect(saved.formulaVersion, 'bia-v1');
        expect(saved.deviceModel, 'QN-Scale');
        expect(saved.rawPayload, '100b15256c0101ba01f472');
        expect(saved.bodyFatPct, isNotNull);
        expect(saved.waterPct, isNotNull);
        expect(saved.bmrKcal, isNotNull);
      },
    );

    test(
      'NON inventa le percentuali che una sola resistenza non può dare',
      () async {
        // Muscolo scheletrico, ossa, proteine, grasso sottocutaneo e indice
        // viscerale la bilancia li stampa, ma da un solo numero non si ricavano
        // sei grandezze indipendenti: restano vuoti invece di sembrare misure.
        final value = reading();
        await repository.addScaleMeasurement(
          profileId: profileId,
          reading: value,
          composition: estimateFor(value),
        );

        final saved = await single();
        expect(saved.musclePct, isNull);
        expect(saved.skeletalMusclePct, isNull);
        expect(saved.bonePct, isNull);
        expect(saved.proteinPct, isNull);
        expect(saved.subcutaneousFatPct, isNull);
        expect(saved.visceralFatIndex, isNull);
      },
    );

    test(
      'scrive la lettura di corpo intero senza dichiarare una frequenza',
      () async {
        final value = reading();
        await repository.addScaleMeasurement(
          profileId: profileId,
          reading: value,
          composition: estimateFor(value),
        );

        final impedances = await database
            .select(database.bodyImpedanceReadings)
            .get();
        final whole = impedances.single;
        expect(whole.segment, 'whole');
        expect(whole.ohm, 442);
        // La QN-Scale non dichiara a che frequenza misura: scriverci «50 kHz»
        // sarebbe salvare una supposizione accanto a una misura.
        expect(whole.frequencyHz, isNull);
      },
    );

    test('senza contatto elettrodi resta il peso, e le percentuali restano '
        'vuote', () async {
      await repository.addScaleMeasurement(
        profileId: profileId,
        reading: reading(impedanceOhm: null),
      );

      final saved = await single();
      expect(saved.weightKg, closeTo(95.8, 0.001));
      expect(saved.hasImpedance, isFalse);
      expect(saved.impedanceOhm, isNull);
      expect(saved.bodyFatPct, isNull);
      expect(saved.formulaVersion, isNull);
      expect(
        await database.select(database.bodyImpedanceReadings).get(),
        isEmpty,
      );
    });

    test('salvare due volte la stessa pesata dà un errore leggibile, non un '
        'doppione', () async {
      final value = reading();
      await repository.addScaleMeasurement(
        profileId: profileId,
        reading: value,
        composition: estimateFor(value),
      );

      expect(
        () => repository.addScaleMeasurement(
          profileId: profileId,
          reading: value,
          composition: estimateFor(value),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Questa pesata è già registrata.',
          ),
        ),
      );
      expect(
        (await database.select(database.bodyMeasurements).get()).length,
        1,
      );
    });

    test('due pesate distinte convivono', () async {
      final first = reading();
      final second = reading(
        weightKg: 95.4,
        measuredAt: DateTime.utc(2026, 8, 7, 5, 20),
      );
      await repository.addScaleMeasurement(
        profileId: profileId,
        reading: first,
        composition: estimateFor(first),
      );
      await repository.addScaleMeasurement(
        profileId: profileId,
        reading: second,
        composition: estimateFor(second),
      );
      expect(
        (await database.select(database.bodyMeasurements).get()).length,
        2,
      );
    });

    test(
      'la pesata entra nella coda di sincronizzazione con la sua sorgente',
      () async {
        final value = reading();
        await repository.addScaleMeasurement(
          profileId: profileId,
          reading: value,
          composition: estimateFor(value),
        );

        final payload = (await outbox()).single;
        expect(payload['source'], 'renpho_ble');
        expect(payload['impedance_ohm'], 442);
        expect(payload['formula_version'], 'bia-v1');
        expect(payload['raw_payload'], '100b15256c0101ba01f472');
        expect(payload['external_id'], startsWith('ble-'));
      },
    );

    test(
      'un peso impossibile viene rifiutato prima di toccare il database',
      () async {
        expect(
          () => repository.addScaleMeasurement(
            profileId: profileId,
            reading: reading(weightKg: 3),
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });

  group('ricalcolo dello storico', () {
    /// Una pesata vecchia, calcolata con una formula di ieri.
    Future<String> seedOldFormulaRow({
      String formulaVersion = 'bia-v0',
      double impedanceOhm = 442,
    }) async {
      final id = 'old-${formulaVersion}_$impedanceOhm';
      final now = AppTime.nowUtc();
      await database
          .into(database.bodyMeasurements)
          .insert(
            BodyMeasurementsCompanion.insert(
              id: id,
              profileId: profileId,
              weightKg: 95.8,
              measuredAt: DateTime.utc(2026, 8, 1, 5, 0),
              hasImpedance: const Value(true),
              impedanceOhm: Value(impedanceOhm),
              bodyFatPct: const Value(11.1),
              waterPct: const Value(70),
              bmrKcal: const Value(1000),
              formulaVersion: Value(formulaVersion),
              source: const Value('renpho_ble'),
              externalId: Value(id),
              createdAt: now,
              updatedAt: now,
            ),
          );
      return id;
    }

    test(
      'rifà solo le righe calcolate da noi con una versione precedente',
      () async {
        final ours = await seedOldFormulaRow();
        // Una pesata inserita a mano dal display della bilancia: numeri
        // dichiarati da altri, senza versione di formula.
        await repository.addMeasurement(
          profileId: profileId,
          weightKg: 95.8,
          measuredAt: DateTime.utc(2026, 8, 2, 5, 0),
          bodyFatPct: 25.2,
          impedanceOhm: 442,
        );

        final pending = await repository.pendingRecalculation(
          profileId: profileId,
        );
        expect(pending.map((row) => row.id), [ours]);

        final done = await repository.recalculateComposition(
          profileId: profileId,
          heightCm: 182,
          birthDate: marcoBirth,
          sexCode: 'M',
        );
        expect(done, 1);

        final rows = await database.select(database.bodyMeasurements).get();
        final rewritten = rows.firstWhere((row) => row.id == ours);
        expect(rewritten.formulaVersion, 'bia-v1');
        expect(rewritten.bodyFatPct, isNot(closeTo(11.1, 0.001)));
        expect(rewritten.impedanceOhm, 442, reason: 'la misura non si tocca');

        final untouched = rows.firstWhere((row) => row.id != ours);
        expect(untouched.bodyFatPct, closeTo(25.2, 0.001));
        expect(untouched.formulaVersion, isNull);
      },
    );

    test('il ricalcolo usa l’età che Marco aveva quel giorno', () async {
      // Stessa impedenza, due pesate a cavallo del compleanno: l'anno in più
      // vale 127 grammi di massa magra, e ricalcolare tutto con l'età di oggi
      // riscriverebbe il passato con un dato che allora non era vero.
      final now = AppTime.nowUtc();
      for (final (id, day) in [
        ('prima', DateTime.utc(2026, 9, 12, 6, 0)),
        ('dopo', DateTime.utc(2026, 9, 14, 6, 0)),
      ]) {
        await database
            .into(database.bodyMeasurements)
            .insert(
              BodyMeasurementsCompanion.insert(
                id: id,
                profileId: profileId,
                weightKg: 95.8,
                measuredAt: day,
                hasImpedance: const Value(true),
                impedanceOhm: const Value(442),
                bodyFatPct: const Value(11.1),
                formulaVersion: const Value('bia-v0'),
                source: const Value('renpho_ble'),
                externalId: Value(id),
                createdAt: now,
                updatedAt: now,
              ),
            );
      }

      await repository.recalculateComposition(
        profileId: profileId,
        heightCm: 182,
        birthDate: marcoBirth,
        sexCode: 'M',
      );

      final rows = await database.select(database.bodyMeasurements).get();
      final before = rows.firstWhere((row) => row.id == 'prima');
      final after = rows.firstWhere((row) => row.id == 'dopo');
      // Un anno in più: 0,127 kg di massa magra in meno, cioè un filo di
      // grasso in più a parità di peso.
      expect(after.bodyFatPct!, greaterThan(before.bodyFatPct!));
      expect(
        (after.bodyFatPct! - before.bodyFatPct!) * 95.8 / 100,
        closeTo(0.127, 0.001),
      );
    });

    test('senza i dati del profilo non riscrive niente', () async {
      await seedOldFormulaRow();
      final done = await repository.recalculateComposition(
        profileId: profileId,
        heightCm: null,
        birthDate: null,
        sexCode: null,
      );
      expect(done, 0);
      final row = await single();
      expect(row.formulaVersion, 'bia-v0');
      expect(row.bodyFatPct, closeTo(11.1, 0.001));
    });

    test('una riga fuori dal dominio della formula resta com’era', () async {
      // Impedenza fuori scala: la formula tace, e tacere vuol dire lasciare
      // la riga com'è invece di svuotarla.
      await seedOldFormulaRow(impedanceOhm: 40);
      final done = await repository.recalculateComposition(
        profileId: profileId,
        heightCm: 182,
        birthDate: marcoBirth,
        sexCode: 'M',
      );
      expect(done, 0);
      expect((await single()).formulaVersion, 'bia-v0');
    });

    test(
      'niente da rifare quando tutto è già alla versione corrente',
      () async {
        final value = reading();
        await repository.addScaleMeasurement(
          profileId: profileId,
          reading: value,
          composition: estimateFor(value),
        );
        expect(
          await repository.pendingRecalculation(profileId: profileId),
          isEmpty,
        );
        expect(
          await repository.recalculateComposition(
            profileId: profileId,
            heightCm: 182,
            birthDate: marcoBirth,
            sexCode: 'M',
          ),
          0,
        );
      },
    );

    test('le righe rifatte tornano nella coda di sincronizzazione', () async {
      await seedOldFormulaRow();
      await repository.recalculateComposition(
        profileId: profileId,
        heightCm: 182,
        birthDate: marcoBirth,
        sexCode: 'M',
      );
      final payload = (await outbox()).single;
      expect(payload['formula_version'], 'bia-v1');
      expect(payload['impedance_ohm'], 442);
    });
  });
}

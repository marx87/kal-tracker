import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/domain/bia_formula.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/body/domain/scale_session.dart';
import 'package:uuid/uuid.dart';

/// Lettura e scrittura delle pesate con composizione corporea.
///
/// Vive accanto a `WellbeingRepository`, che tocca le stesse tabelle per il
/// caso semplice (peso e basta) del diario: qui si aggiungono impedenza,
/// percentuali e circonferenze, che il diario non conosce.
///
/// Si salva solo ciò che è stato misurato o dichiarato. Età metabolica, peso
/// ottimale e tipo di corpo la bilancia li stampa sul display ma non entrano
/// né nel database né nella UI: sono giudizi, non misure.
class BodyRepository {
  BodyRepository(this._database, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  /// La provenienza delle pesate lette via Bluetooth. È metà della UNIQUE che
  /// deduplica, quindi non è una decorazione.
  static const scaleSource = 'renpho_ble';

  /// Quante circonferenze si accettano in una sola pesata. Non è un limite
  /// del database: è il punto oltre il quale il foglio di inserimento smette
  /// di essere compilabile.
  static const maxCircumferences = 12;

  /// Le pesate del periodo, dalla più recente, con le loro circonferenze.
  ///
  /// [since] deve già comprendere i giorni di riscaldamento della media
  /// mobile: chi chiama sottrae `BodyAnalysis.warmupDays` alla finestra
  /// visibile, altrimenti il primo punto del grafico sarebbe una media a un
  /// giorno solo travestita da media a sette.
  /// Il peso dell'ultima pesata salvata, o `null` se non ce n'è nessuna.
  ///
  /// Lettura secca e non uno stream, ed è una correzione: presa da
  /// `watchMeasurements(...).first` bloccava l'avvio della sessione con la
  /// bilancia finché lo stream non avesse emesso — e in un test, o su un
  /// database appena aperto, quel momento può non arrivare mai.
  ///
  /// Serve a presentarsi alla bilancia **prima** di salirci: senza un peso da
  /// mettere nel profilo non ci si può annunciare, e senza annuncio la
  /// bilancia non consegna la pesata che tiene in memoria.
  Future<double?> latestWeightKg({required String profileId}) async {
    final measurements = _database.bodyMeasurements;
    final query = _database.select(measurements)
      ..where((row) => row.profileId.equals(profileId) & row.deletedAt.isNull())
      ..orderBy([(row) => OrderingTerm.desc(row.measuredAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.weightKg;
  }

  Stream<List<BodyMeasurement>> watchMeasurements({
    required String profileId,
    DateTime? since,
  }) {
    final measurements = _database.bodyMeasurements;
    final values = _database.bodyMeasurementValues;

    final query = _database.select(measurements).join([
      leftOuterJoin(values, values.measurementId.equalsExp(measurements.id)),
    ]);
    var filter =
        measurements.profileId.equals(profileId) &
        measurements.deletedAt.isNull();
    if (since != null) {
      filter =
          filter & measurements.measuredAt.isBiggerOrEqualValue(since.toUtc());
    }
    query
      ..where(filter)
      ..orderBy([OrderingTerm.desc(measurements.measuredAt)]);

    return query.watch().map((rows) {
      // Una riga per circonferenza: si ricompone la pesata mantenendo
      // l'ordine di arrivo, che è già quello del `measured_at` decrescente.
      final byId = <String, LocalBodyMeasurement>{};
      final circumferences = <String, Map<String, double>>{};
      for (final row in rows) {
        final measurement = row.readTable(measurements);
        byId[measurement.id] = measurement;
        final value = row.readTableOrNull(values);
        if (value != null) {
          circumferences.putIfAbsent(
            measurement.id,
            () => <String, double>{},
          )[value.label] = value.value;
        }
      }

      return byId.values
          .map(
            (row) => BodyMeasurement(
              id: row.id,
              measuredAt: row.measuredAt,
              weightKg: row.weightKg,
              hasImpedance: row.hasImpedance,
              bodyFatPct: row.bodyFatPct,
              musclePct: row.musclePct,
              waterPct: row.waterPct,
              impedanceOhm: row.impedanceOhm,
              source: row.source,
              note: row.note,
              circumferences: Map.unmodifiable(
                circumferences[row.id] ?? const <String, double>{},
              ),
            ),
          )
          .toList(growable: false);
    });
  }

  /// Registra una pesata manuale, con o senza impedenza.
  ///
  /// Senza [bodyFatPct] resta una pesata di solo peso: i derivati NON si
  /// inventano, restano vuoti. È il caso della salita in fretta a piedi
  /// asciutti, in cui la bilancia dà solo i kg.
  Future<String> addMeasurement({
    required String profileId,
    required double weightKg,
    required DateTime measuredAt,
    double? bodyFatPct,
    double? musclePct,
    double? waterPct,
    double? impedanceOhm,
    String? note,
    Map<String, double> circumferences = const {},
  }) async {
    _checkRange(weightKg, min: 20, max: 500, what: 'Il peso', unit: 'kg');
    _checkPercent(bodyFatPct, 'La percentuale di grasso');
    _checkPercent(musclePct, 'La percentuale di muscolo');
    _checkPercent(waterPct, 'La percentuale di acqua');
    if (impedanceOhm != null) {
      _checkRange(
        impedanceOhm,
        min: 1,
        max: 2000,
        what: 'L’impedenza',
        unit: 'ohm',
      );
    }
    final cleanNote = _cleanNote(note);
    final cleanCircumferences = _cleanCircumferences(circumferences);

    final id = _uuid.v4();
    final now = AppTime.nowUtc();
    final instant = measuredAt.toUtc();
    // La lettura completa si riconosce dalla percentuale di grasso: senza
    // quella non si separa la massa grassa dalla magra, ed è quello che
    // l'impedenza serve a produrre.
    final hasImpedance = bodyFatPct != null;

    final values = [
      for (final entry in cleanCircumferences.entries)
        (id: _uuid.v4(), label: entry.key, value: entry.value),
    ];

    await _database.transaction(() async {
      await _database
          .into(_database.bodyMeasurements)
          .insert(
            BodyMeasurementsCompanion.insert(
              id: id,
              profileId: profileId,
              weightKg: weightKg,
              measuredAt: instant,
              hasImpedance: Value(hasImpedance),
              impedanceOhm: Value(impedanceOhm),
              bodyFatPct: Value(bodyFatPct),
              musclePct: Value(musclePct),
              waterPct: Value(waterPct),
              note: Value(cleanNote),
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (final value in values) {
        await _database
            .into(_database.bodyMeasurementValues)
            .insert(
              BodyMeasurementValuesCompanion.insert(
                id: value.id,
                measurementId: id,
                label: value.label,
                value: value.value,
              ),
            );
      }
      await _appendOutbox(
        entityId: id,
        operation: 'upsert',
        payload: _payload(
          id: id,
          profileId: profileId,
          weightKg: weightKg,
          measuredAt: instant,
          hasImpedance: hasImpedance,
          impedanceOhm: impedanceOhm,
          bodyFatPct: bodyFatPct,
          musclePct: musclePct,
          waterPct: waterPct,
          note: cleanNote,
          updatedAt: now,
          values: values,
        ),
        now: now,
      );
    });
    return id;
  }

  /// Registra una pesata letta dalla bilancia via Bluetooth.
  ///
  /// Differisce da [addMeasurement] in tre punti, tutti conseguenza dello
  /// stesso principio: **si conserva la misura, non il giudizio**.
  ///
  /// 1. `impedanceOhm` è la misura, e viaggia insieme alla `formulaVersion`
  ///    che ha prodotto le percentuali: senza, il ricalcolo dello storico non
  ///    saprebbe quali righe rifare.
  /// 2. `rawPayload` conserva la trama grezza. Se domani si scopre che quel
  ///    pacchetto conteneva un campo che non sapevamo leggere, lo storico si
  ///    ridecodifica invece di ricominciare.
  /// 3. `externalId` è deterministico (istante al minuto + peso in grammi),
  ///    quindi la UNIQUE `(profile_id, source, external_id)` trasforma un
  ///    doppio tocco su «Salva» in un errore leggibile invece che in due
  ///    pesate identiche a un minuto l'una dall'altra.
  ///
  /// [composition] è nulla quando gli elettrodi non hanno fatto contatto o
  /// quando il profilo non ha ancora altezza, nascita e sesso: in quel caso
  /// entra il solo peso, che è un dato buono, e le percentuali restano vuote
  /// invece di essere inventate.
  Future<String> addScaleMeasurement({
    required String profileId,
    required ScaleReading reading,
    BodyCompositionEstimate? composition,
    String? note,
  }) async {
    _checkRange(
      reading.weightKg,
      min: 20,
      max: 500,
      what: 'Il peso',
      unit: 'kg',
    );
    final impedanceOhm = reading.hasImpedance ? reading.impedanceOhm : null;
    if (impedanceOhm != null) {
      _checkRange(
        impedanceOhm,
        min: 1,
        max: 2000,
        what: 'L’impedenza',
        unit: 'ohm',
      );
    }
    final cleanNote = _cleanNote(note);

    final instant = reading.measuredAt.toUtc();
    final externalId = scaleExternalId(
      measuredAt: instant,
      weightKg: reading.weightKg,
    );
    final duplicate =
        await (_database.select(_database.bodyMeasurements)..where(
              (row) =>
                  row.profileId.equals(profileId) &
                  row.source.equals(scaleSource) &
                  row.externalId.equals(externalId),
            ))
            .getSingleOrNull();
    if (duplicate != null) {
      throw const FormatException('Questa pesata è già registrata.');
    }

    final id = _uuid.v4();
    final now = AppTime.nowUtc();
    // Il taglio è alla percentuale di grasso, come per la pesata manuale:
    // senza quella non si separa la massa grassa dalla magra, ed è quello che
    // l'impedenza serve a produrre.
    final hasComposition = composition != null;
    final impedanceReadings =
        <({String id, String segment, int? frequencyHz, double ohm})>[];
    if (impedanceOhm != null) {
      impedanceReadings.add((
        id: _uuid.v4(),
        segment: 'whole',
        frequencyHz: null,
        ohm: impedanceOhm,
      ));
      final segments = reading.segmentOhms;
      if (segments.length >= 3) {
        final minimum = segments.reduce((a, b) => a < b ? a : b);
        if (minimum > 0 && minimum <= 5000) {
          impedanceReadings.add((
            id: _uuid.v4(),
            segment: 'trunk',
            frequencyHz: null,
            ohm: minimum,
          ));
        }
      }
    }

    await _database.transaction(() async {
      await _database
          .into(_database.bodyMeasurements)
          .insert(
            BodyMeasurementsCompanion.insert(
              id: id,
              profileId: profileId,
              weightKg: reading.weightKg,
              measuredAt: instant,
              hasImpedance: Value(hasComposition),
              impedanceOhm: Value(impedanceOhm),
              bodyFatPct: Value(composition?.bodyFatPct),
              waterPct: Value(composition?.waterPct),
              bmrKcal: Value(composition?.bmrKcal),
              formulaVersion: Value(composition?.formulaVersion),
              source: const Value(scaleSource),
              externalId: Value(externalId),
              deviceModel: Value(_clampDevice(reading.deviceName)),
              rawPayload: Value(_clampPayload(reading.rawPayloadHex)),
              note: Value(cleanNote),
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (final impedance in impedanceReadings) {
        // La frequenza resta nulla quando la bilancia non la dichiara:
        // scriverci «50 kHz» sarebbe salvare una supposizione accanto a una
        // misura. Lo stesso vale per il segmento: entra solo quello che il
        // protocollo permette di riconoscere.
        await _database
            .into(_database.bodyImpedanceReadings)
            .insert(
              BodyImpedanceReadingsCompanion.insert(
                id: impedance.id,
                measurementId: id,
                segment: impedance.segment,
                frequencyHz: Value(impedance.frequencyHz),
                ohm: impedance.ohm,
              ),
            );
      }
      await _appendOutbox(
        entityId: id,
        operation: 'upsert',
        payload: {
          'id': id,
          'profile_id': profileId,
          'weight_kg': reading.weightKg,
          'measured_at': instant.toIso8601String(),
          'has_impedance': hasComposition,
          'impedance_ohm': impedanceOhm,
          'body_fat_pct': composition?.bodyFatPct,
          'water_pct': composition?.waterPct,
          'bmr_kcal': composition?.bmrKcal,
          'formula_version': composition?.formulaVersion,
          'source': scaleSource,
          'external_id': externalId,
          'device_model': _clampDevice(reading.deviceName),
          'raw_payload': _clampPayload(reading.rawPayloadHex),
          'note': cleanNote,
          'updated_at': now.toIso8601String(),
          // Una pesata appena letta dalla bilancia non ha circonferenze: la
          // lista vuota è la verità, non un'omissione.
          'values': const <Map<String, Object?>>[],
          'impedance_readings': [
            for (final impedance in impedanceReadings)
              {
                'id': impedance.id,
                'measurement_id': id,
                'segment': impedance.segment,
                'frequency_hz': impedance.frequencyHz,
                'ohm': impedance.ohm,
              },
          ],
        },
        now: now,
      );
    });
    return id;
  }

  /// Riscrive le percentuali delle pesate calcolate da noi con una versione
  /// vecchia della formula.
  ///
  /// **Si toccano solo le righe nostre.** Una pesata con `formula_version`
  /// nulla porta numeri dichiarati da altri — digitati dal display Renpho o
  /// importati dal loro CSV — e non è nostra da rifare: sovrascriverla
  /// sostituirebbe una misura registrata con una nostra stima, che è
  /// esattamente il contrario del patto.
  ///
  /// Torna quante righe sono state riscritte.
  Future<int> recalculateComposition({
    required String profileId,
    required double? heightCm,
    required DateTime? birthDate,
    required String? sexCode,
    BiaFormula? formula,
  }) async {
    final target = formula ?? BiaFormulas.current;
    final rows = await pendingRecalculation(
      profileId: profileId,
      formula: target,
    );
    if (rows.isEmpty) {
      return 0;
    }

    var rewritten = 0;
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      for (final row in rows) {
        final input = biaInputFrom(
          heightCm: heightCm,
          birthDate: birthDate,
          sexCode: sexCode,
          weightKg: row.weightKg,
          impedanceOhm: row.impedanceOhm,
          // L'età di ALLORA, non quella di oggi: ricalcolare il passato con
          // l'anagrafica del presente lo riscriverebbe con un dato che allora
          // non era vero.
          measuredAt: row.measuredAt,
        );
        final estimate = input == null ? null : target.estimate(input);
        if (estimate == null) {
          continue;
        }
        await (_database.update(
          _database.bodyMeasurements,
        )..where((item) => item.id.equals(row.id))).write(
          BodyMeasurementsCompanion(
            bodyFatPct: Value(estimate.bodyFatPct),
            waterPct: Value(estimate.waterPct),
            bmrKcal: Value(estimate.bmrKcal),
            formulaVersion: Value(estimate.formulaVersion),
            updatedAt: Value(now),
          ),
        );
        await _appendOutbox(
          entityId: row.id,
          operation: 'upsert',
          payload: {
            'id': row.id,
            'profile_id': row.profileId,
            'weight_kg': row.weightKg,
            'measured_at': row.measuredAt.toIso8601String(),
            'has_impedance': true,
            'impedance_ohm': row.impedanceOhm,
            'body_fat_pct': estimate.bodyFatPct,
            'water_pct': estimate.waterPct,
            'bmr_kcal': estimate.bmrKcal,
            'formula_version': estimate.formulaVersion,
            'source': row.source,
            'external_id': row.externalId,
            'device_model': row.deviceModel,
            'raw_payload': row.rawPayload,
            'note': row.note,
            'updated_at': now.toIso8601String(),
          },
          now: now,
        );
        rewritten++;
      }
    });
    return rewritten;
  }

  /// Le pesate che una nuova versione della formula rifarebbe. La schermata la
  /// usa per proporre il ricalcolo invece di eseguirlo di nascosto: riscrivere
  /// mesi di storico senza dirlo sarebbe una sorpresa sgradevole.
  Future<List<LocalBodyMeasurement>> pendingRecalculation({
    required String profileId,
    BiaFormula? formula,
  }) async {
    final target = formula ?? BiaFormulas.current;
    final rows =
        await (_database.select(_database.bodyMeasurements)..where(
              (row) =>
                  row.profileId.equals(profileId) &
                  row.deletedAt.isNull() &
                  row.impedanceOhm.isNotNull() &
                  row.formulaVersion.isNotNull() &
                  row.formulaVersion.equals(target.version).not(),
            ))
            .get();
    return rows
        .where((row) => BiaFormulas.isOurs(row.formulaVersion))
        .toList(growable: false);
  }

  /// La chiave con cui una pesata Bluetooth si riconosce: minuto e peso in
  /// grammi. Due letture separate da meno di un minuto e identiche al grammo
  /// sono la stessa salita sulla bilancia salvata due volte.
  static String scaleExternalId({
    required DateTime measuredAt,
    required double weightKg,
  }) {
    final at = measuredAt.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${at.year}${two(at.month)}${two(at.day)}'
        'T${two(at.hour)}${two(at.minute)}';
    return 'ble-$stamp-${(weightKg * 1000).round()}';
  }

  static String? _clampDevice(String name) {
    final clean = name.trim();
    if (clean.isEmpty) {
      return null;
    }
    return clean.length <= 60 ? clean : clean.substring(0, 60);
  }

  static String? _clampPayload(String hex) {
    final clean = hex.trim();
    if (clean.isEmpty) {
      return null;
    }
    return clean.length <= 512 ? clean : clean.substring(0, 512);
  }

  /// Cancellazione morbida, come nel resto dell'app: la riga resta, così la
  /// sincronizzazione può propagarla e [restoreMeasurement] può disfarla.
  Future<void> deleteMeasurement(String id) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(
            _database.bodyMeasurements,
          )..where((row) => row.id.equals(id) & row.deletedAt.isNull())).write(
            BodyMeasurementsCompanion(
              updatedAt: Value(now),
              deletedAt: Value(now),
            ),
          );
      if (changed == 0) {
        return;
      }
      await _appendOutbox(
        entityId: id,
        operation: 'delete',
        payload: {'id': id, 'deleted_at': now.toIso8601String()},
        now: now,
      );
    });
  }

  /// Annulla la cancellazione. Le circonferenze non sono mai state tolte da
  /// qui, ma tornano nel payload perché in remoto la cancellazione le aveva
  /// staccate dalla pesata.
  Future<void> restoreMeasurement(String id) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final row = await (_database.select(
        _database.bodyMeasurements,
      )..where((item) => item.id.equals(id))).getSingleOrNull();
      if (row == null) {
        throw StateError('Pesata non trovata.');
      }
      if (row.deletedAt == null) {
        return;
      }
      await (_database.update(
        _database.bodyMeasurements,
      )..where((item) => item.id.equals(id))).write(
        BodyMeasurementsCompanion(
          updatedAt: Value(now),
          deletedAt: const Value(null),
        ),
      );
      final values = await (_database.select(
        _database.bodyMeasurementValues,
      )..where((item) => item.measurementId.equals(id))).get();
      final impedanceReadings = await (_database.select(
        _database.bodyImpedanceReadings,
      )..where((item) => item.measurementId.equals(id))).get();
      await _appendOutbox(
        entityId: id,
        operation: 'upsert',
        payload: _payload(
          id: id,
          profileId: row.profileId,
          weightKg: row.weightKg,
          measuredAt: row.measuredAt,
          hasImpedance: row.hasImpedance,
          impedanceOhm: row.impedanceOhm,
          bodyFatPct: row.bodyFatPct,
          musclePct: row.musclePct,
          waterPct: row.waterPct,
          skeletalMusclePct: row.skeletalMusclePct,
          bonePct: row.bonePct,
          proteinPct: row.proteinPct,
          subcutaneousFatPct: row.subcutaneousFatPct,
          visceralFatIndex: row.visceralFatIndex,
          bmrKcal: row.bmrKcal,
          formulaVersion: row.formulaVersion,
          source: row.source,
          externalId: row.externalId,
          deviceModel: row.deviceModel,
          rawPayload: row.rawPayload,
          note: row.note,
          updatedAt: now,
          values: [
            for (final value in values)
              (id: value.id, label: value.label, value: value.value),
          ],
          impedanceReadings: [
            for (final reading in impedanceReadings)
              {
                'id': reading.id,
                'measurement_id': id,
                'segment': reading.segment,
                'frequency_hz': reading.frequencyHz,
                'ohm': reading.ohm,
              },
          ],
        ),
        now: now,
      );
    });
  }

  Map<String, Object?> _payload({
    required String id,
    required String profileId,
    required double weightKg,
    required DateTime measuredAt,
    required bool hasImpedance,
    required double? impedanceOhm,
    required double? bodyFatPct,
    required double? musclePct,
    required double? waterPct,
    double? skeletalMusclePct,
    double? bonePct,
    double? proteinPct,
    double? subcutaneousFatPct,
    int? visceralFatIndex,
    int? bmrKcal,
    String? formulaVersion,
    String source = 'manual',
    String? externalId,
    String? deviceModel,
    String? rawPayload,
    required String? note,
    required DateTime updatedAt,
    required List<({String id, String label, double value})> values,
    List<Map<String, Object?>> impedanceReadings = const [],
  }) => {
    'id': id,
    'profile_id': profileId,
    'weight_kg': weightKg,
    'measured_at': measuredAt.toIso8601String(),
    'has_impedance': hasImpedance,
    'impedance_ohm': impedanceOhm,
    'body_fat_pct': bodyFatPct,
    'muscle_pct': musclePct,
    'skeletal_muscle_pct': skeletalMusclePct,
    'bone_pct': bonePct,
    'protein_pct': proteinPct,
    'water_pct': waterPct,
    'subcutaneous_fat_pct': subcutaneousFatPct,
    'visceral_fat_index': visceralFatIndex,
    'bmr_kcal': bmrKcal,
    'formula_version': formulaVersion,
    'source': source,
    'external_id': externalId,
    'device_model': deviceModel,
    'raw_payload': rawPayload,
    'note': note,
    'updated_at': updatedAt.toIso8601String(),
    // La chiave `values` presente significa «questa scrittura parla anche
    // delle circonferenze»: ometterla le lascerebbe stare, mandarla vuota le
    // cancella. Qui la pesata è appena stata scritta per intero, quindi la
    // lista — anche vuota — è la verità.
    'values': [
      for (final value in values)
        {
          'id': value.id,
          'measurement_id': id,
          'label': value.label,
          'value': value.value,
        },
    ],
    'impedance_readings': impedanceReadings,
  };

  Future<void> _appendOutbox({
    required String entityId,
    required String operation,
    required Map<String, Object?> payload,
    required DateTime now,
  }) => _database
      .into(_database.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          id: _uuid.v4(),
          entityType: 'body_measurement',
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: now,
        ),
      );

  static void _checkRange(
    double value, {
    required double min,
    required double max,
    required String what,
    required String unit,
  }) {
    if (!value.isFinite || value < min || value > max) {
      throw FormatException(
        '$what deve stare tra ${min.round()} e ${max.round()} $unit.',
      );
    }
  }

  static void _checkPercent(double? value, String what) {
    if (value == null) {
      return;
    }
    if (!value.isFinite || value <= 0 || value > 100) {
      throw FormatException('$what deve stare tra 0 e 100.');
    }
  }

  static String? _cleanNote(String? note) {
    final clean = note?.trim();
    if (clean == null || clean.isEmpty) {
      return null;
    }
    if (clean.length > 240) {
      throw const FormatException('La nota è troppo lunga.');
    }
    return clean;
  }

  static Map<String, double> _cleanCircumferences(Map<String, double> input) {
    final clean = <String, double>{};
    for (final entry in input.entries) {
      final label = entry.key.trim();
      if (label.isEmpty) {
        continue;
      }
      if (label.length > 40) {
        throw const FormatException('Il nome della misura è troppo lungo.');
      }
      final value = entry.value;
      if (!value.isFinite || value <= 0 || value > 1000) {
        throw FormatException('La misura «$label» non è valida.');
      }
      clean[label] = value;
    }
    if (clean.length > maxCircumferences) {
      throw const FormatException('Troppe circonferenze in una sola pesata.');
    }
    return clean;
  }
}

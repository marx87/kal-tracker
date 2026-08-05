import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
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
          note: row.note,
          updatedAt: now,
          values: [
            for (final value in values)
              (id: value.id, label: value.label, value: value.value),
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
    required String? note,
    required DateTime updatedAt,
    required List<({String id, String label, double value})> values,
  }) => {
    'id': id,
    'profile_id': profileId,
    'weight_kg': weightKg,
    'measured_at': measuredAt.toIso8601String(),
    'has_impedance': hasImpedance,
    'impedance_ohm': impedanceOhm,
    'body_fat_pct': bodyFatPct,
    'muscle_pct': musclePct,
    'water_pct': waterPct,
    'source': 'manual',
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

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/onboarding/domain/personal_details.dart';
import 'package:uuid/uuid.dart';

/// Legge e scrive i tre dati anagrafici sul profilo.
///
/// Vivono in `app_profiles` — colonne `height_cm`, `birth_date`, `sex`,
/// aggiunte dalla v5 — e fino a oggi nessuna schermata li scriveva: c'erano
/// le colonne, la migrazione remota e le formule che le usano, ma non un
/// posto in cui dirle. Questo repository è quel posto.
class PersonalDetailsRepository {
  PersonalDetailsRepository(this._database);

  final AppDatabase _database;

  Future<PersonalDetails> read(String profileId) async {
    final row = await (_database.select(
      _database.appProfiles,
    )..where((profile) => profile.id.equals(profileId))).getSingleOrNull();
    if (row == null) {
      return PersonalDetails.empty;
    }
    return PersonalDetails(
      heightCm: row.heightCm,
      // Drift rilegge i `DateTime` nel fuso locale: senza `toUtc()` il
      // compleanno tornerebbe indietro di due ore, e a mezzanotte di un
      // giorno diventerebbe il giorno prima.
      birthDate: row.birthDate == null
          ? null
          : PersonalDetails.dayFrom(row.birthDate!.toUtc()),
      sex: BiologicalSex.fromCode(row.sex),
    );
  }

  /// Scrive tutti e tre i campi, compresi quelli vuoti.
  ///
  /// È una sostituzione e non una fusione di proposito: la stessa schermata
  /// serve a compilarli la prima volta e a correggerli dopo, e in quel
  /// secondo caso svuotare un campo deve significare svuotarlo davvero.
  Future<void> write(String profileId, PersonalDetails details) async {
    final row = await (_database.select(
      _database.appProfiles,
    )..where((profile) => profile.id.equals(profileId))).getSingleOrNull();
    if (row == null) {
      throw StateError('Profilo non trovato.');
    }
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      await (_database.update(
        _database.appProfiles,
      )..where((profile) => profile.id.equals(profileId))).write(
        AppProfilesCompanion(
          heightCm: Value(details.heightCm),
          birthDate: Value(details.birthDate),
          sex: Value(details.sex?.code),
          updatedAt: Value(now),
        ),
      );
      await _database
          .into(_database.syncOutbox)
          .insert(
            SyncOutboxCompanion.insert(
              id: const Uuid().v4(),
              entityType: 'profile',
              entityId: profileId,
              operation: 'upsert',
              payloadJson: jsonEncode({
                'id': profileId,
                'display_name': row.displayName,
                'height_cm': details.heightCm,
                'birth_date': _day(details.birthDate),
                'sex': details.sex?.code,
                'created_at': row.createdAt.toUtc().toIso8601String(),
                'updated_at': now.toIso8601String(),
                'deleted_at': null,
              }),
              createdAt: now,
            ),
          );
    });
  }

  static String? _day(DateTime? value) {
    if (value == null) {
      return null;
    }
    final day = value.toUtc();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${day.year}-${two(day.month)}-${two(day.day)}';
  }
}

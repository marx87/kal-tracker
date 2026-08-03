import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:uuid/uuid.dart';

class LocalProfileRepository {
  LocalProfileRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Future<LocalProfile> getOrCreateMarco() async {
    final existingQuery = _database.select(_database.appProfiles)..limit(1);
    final existing = await existingQuery.getSingleOrNull();
    if (existing != null) {
      return existing;
    }

    final now = AppTime.nowUtc();
    final id = _uuid.v4();
    await _database
        .into(_database.appProfiles)
        .insert(
          AppProfilesCompanion.insert(
            id: id,
            displayName: 'Marco',
            createdAt: now,
            updatedAt: now,
          ),
        );

    return (_database.select(
      _database.appProfiles,
    )..where((profile) => profile.id.equals(id))).getSingle();
  }
}

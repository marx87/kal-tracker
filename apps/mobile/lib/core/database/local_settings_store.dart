import 'package:kal_tracker/core/database/app_database.dart';

/// Le poche impostazioni legate a **questo apparecchio**.
///
/// Non passano dalla sincronizzazione, e non è una svista: l'indirizzo
/// Bluetooth della bilancia è il MAC che vede questo telefono, e mandarlo al
/// tablet significherebbe dirgli di collegarsi a un indirizzo che lì non
/// esiste. Ogni chiave qui dentro deve superare la stessa prova — «avrebbe
/// senso su un altro dispositivo?». Se la risposta è no, il posto è questo.
class LocalSettingsStore {
  LocalSettingsStore(this._db);

  final AppDatabase _db;

  /// L'indirizzo della bilancia scelta a mano una volta per tutte.
  static const scaleDeviceId = 'scale.device_id';

  /// Il nome con cui si era annunciata, solo da mostrare.
  static const scaleDeviceName = 'scale.device_name';

  Future<String?> read(String key) async {
    final row = await (_db.select(
      _db.localSettings,
    )..where((table) => table.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> write(String key, String value) => _db
      .into(_db.localSettings)
      .insertOnConflictUpdate(
        LocalSettingsCompanion.insert(
          key: key,
          value: value,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

  Future<void> remove(String key) => (_db.delete(
    _db.localSettings,
  )..where((table) => table.key.equals(key))).go();
}

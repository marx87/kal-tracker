import 'dart:convert';
import 'dart:io';

import 'package:kal_tracker/features/wellbeing/domain/water_settings.dart';
import 'package:path_provider/path_provider.dart';

/// Persistenza delle impostazioni acqua (obiettivo + promemoria).
///
/// Interfaccia minima così i test usano un fake in memoria e la UI
/// non tocca mai il filesystem direttamente.
abstract class WaterSettingsStore {
  Future<WaterSettings> read();
  Future<void> write(WaterSettings settings);
}

/// Store su file JSON nella directory di supporto dell'app
/// (stesso pattern di FileBackupStorage: letture indulgenti,
/// scritture best-effort, mai un crash per un file rovinato).
class FileWaterSettingsStore implements WaterSettingsStore {
  FileWaterSettingsStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const String fileName = 'kal-tracker-water-settings.json';

  final Future<Directory> Function() _directory;

  @override
  Future<WaterSettings> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return const WaterSettings();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const WaterSettings();
      }
      return WaterSettings.fromJson(decoded);
    } on Object {
      return const WaterSettings();
    }
  }

  @override
  Future<void> write(WaterSettings settings) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(settings.toJson()), flush: true);
    } on Object {
      // Best effort: lo stato in memoria resta coerente per la sessione.
      return;
    }
  }

  Future<File> _file() async {
    final directory = await _directory();
    return File('${directory.path}/$fileName');
  }
}

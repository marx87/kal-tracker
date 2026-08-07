import 'dart:convert';
import 'dart:io';

import 'package:kal_tracker/features/goal/domain/activity_multiplier.dart';
import 'package:path_provider/path_provider.dart';

/// Persistenza di quanto ci si muove: il livello scelto e il moltiplicatore
/// derivato che Marco ha accettato.
///
/// Su file JSON e non in una colonna perché lo schema è alla v9 e questo
/// arriva dopo: è lo stesso posto in cui vivono le impostazioni acqua, e in
/// cui è vissuto l'Obiettivo fino alla v6. Il giorno che una colonna ci sarà,
/// la migrazione è quella di `FileGoalStore` — si legge una volta e si
/// archivia.
///
/// Stesso patto degli altri store: letture indulgenti, scritture best effort,
/// mai un crash. Un livello di attività perso si riscrive in due tocchi.
abstract class ActivitySettingsStore {
  Future<ActivitySettings> read();
  Future<void> write(ActivitySettings settings);
}

class FileActivitySettingsStore implements ActivitySettingsStore {
  FileActivitySettingsStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const String fileName = 'kal-tracker-activity.json';

  final Future<Directory> Function() _directory;

  @override
  Future<ActivitySettings> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return const ActivitySettings();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const ActivitySettings();
      }
      return ActivitySettings.fromJson(decoded);
    } on Object {
      return const ActivitySettings();
    }
  }

  @override
  Future<void> write(ActivitySettings settings) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(settings.toJson()), flush: true);
    } on Object {
      // Lo stato in memoria resta coerente per la sessione.
      return;
    }
  }

  Future<File> _file() async {
    final directory = await _directory();
    return File('${directory.path}/$fileName');
  }
}

/// Store in memoria: serve ai test e ai widget test, che non hanno
/// `path_provider`.
class InMemoryActivitySettingsStore implements ActivitySettingsStore {
  InMemoryActivitySettingsStore([this._settings = const ActivitySettings()]);

  ActivitySettings _settings;

  ActivitySettings get current => _settings;

  @override
  Future<ActivitySettings> read() async => _settings;

  @override
  Future<void> write(ActivitySettings settings) async => _settings = settings;
}

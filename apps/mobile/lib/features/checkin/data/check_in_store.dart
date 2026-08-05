import 'dart:convert';
import 'dart:io';

import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:path_provider/path_provider.dart';

/// Persistenza del check-in del mattino.
///
/// **Perché un file e non una tabella.** Sonno ed energia non hanno ancora
/// una tabella in Drift e `app_database.dart` è condiviso: aggiungerne una
/// qui significherebbe una migrazione fuori tempo, in mezzo al lavoro di
/// altri. L'interfaccia è però già quella giusta — leggi tutto, scrivi tutto
/// — quindi il giorno in cui la tabella arriva cambia solo l'implementazione.
/// Lo schema che serve è scritto nelle note di consegna.
///
/// Stesso patto di `FileGoalStore` e `FileWaterSettingsStore`: letture
/// indulgenti, scritture best effort, mai un crash per un file rovinato. Un
/// check-in perso è un fastidio, un'app che non si apre è un disastro.
abstract class CheckInStore {
  Future<CheckInLog> read();
  Future<void> write(CheckInLog log);
}

class FileCheckInStore implements CheckInStore {
  FileCheckInStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const String fileName = 'kal-tracker-checkin.json';

  final Future<Directory> Function() _directory;

  @override
  Future<CheckInLog> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return const CheckInLog.empty();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const CheckInLog.empty();
      }
      return CheckInLog.fromJson(decoded);
    } on Object {
      return const CheckInLog.empty();
    }
  }

  @override
  Future<void> write(CheckInLog log) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(log.toJson()), flush: true);
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

/// Store in memoria: serve ai test e a un ambiente senza filesystem (i widget
/// test non hanno `path_provider`).
class InMemoryCheckInStore implements CheckInStore {
  InMemoryCheckInStore([this._log = const CheckInLog.empty()]);

  CheckInLog _log;

  @override
  Future<CheckInLog> read() async => _log;

  @override
  Future<void> write(CheckInLog log) async => _log = log;
}

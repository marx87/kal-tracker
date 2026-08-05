import 'dart:convert';
import 'dart:io';

import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:path_provider/path_provider.dart';

/// Persistenza dell'Obiettivo.
///
/// **Perché un file e non una tabella.** Lo schema Drift non ha ancora
/// `goals` e `app_database.dart` è condiviso: aggiungere una tabella qui
/// significherebbe una migrazione fuori tempo. L'interfaccia però è già
/// quella giusta — leggi tutto, scrivi tutto — quindi il giorno in cui la
/// tabella arriva cambia solo l'implementazione, non i chiamanti.
/// Lo schema che serve è scritto nelle note di consegna.
abstract class GoalStore {
  Future<GoalHistory> read();
  Future<void> write(GoalHistory history);
}

/// Store su file JSON nella directory di supporto dell'app: stesso patto di
/// `FileWaterSettingsStore` — letture indulgenti, scritture best effort, mai
/// un crash per un file rovinato. Un obiettivo perso è un fastidio, un'app
/// che non si apre è un disastro.
class FileGoalStore implements GoalStore {
  FileGoalStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const String fileName = 'kal-tracker-goal.json';

  final Future<Directory> Function() _directory;

  @override
  Future<GoalHistory> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return const GoalHistory.empty();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const GoalHistory.empty();
      }
      return GoalHistory.fromJson(decoded);
    } on Object {
      return const GoalHistory.empty();
    }
  }

  @override
  Future<void> write(GoalHistory history) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(history.toJson()), flush: true);
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

/// Store in memoria: serve ai test e alla prima esecuzione in un ambiente
/// senza filesystem (i widget test non hanno `path_provider`).
class InMemoryGoalStore implements GoalStore {
  InMemoryGoalStore([this._history = const GoalHistory.empty()]);

  GoalHistory _history;

  @override
  Future<GoalHistory> read() async => _history;

  @override
  Future<void> write(GoalHistory history) async => _history = history;
}

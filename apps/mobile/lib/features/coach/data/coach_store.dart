import 'dart:convert';
import 'dart:io';

import 'package:kal_tracker/features/coach/domain/coach_narrative.dart';
import 'package:path_provider/path_provider.dart';

/// Persistenza del poco che il coach ricorda: l'ultimo commento, la richiesta
/// in volo, l'ultimo errore.
///
/// **Perché un file e non una tabella.** I numeri del rapporto si ricalcolano
/// dal database a ogni apertura, quindi non c'è niente di grosso da salvare;
/// e `app_database.dart` è condiviso, aggiungere una tabella qui significa
/// una migrazione fuori tempo. L'interfaccia è già quella giusta — leggi
/// tutto, scrivi tutto — quindi il giorno in cui la tabella arriva cambia
/// solo l'implementazione.
abstract class CoachStore {
  Future<CoachArchive> read();
  Future<void> write(CoachArchive archive);
}

/// Store su file JSON nella directory di supporto dell'app: stesso patto di
/// `FileGoalStore`. Letture indulgenti, scritture best effort, mai un crash
/// per un file rovinato. Un commento perso è un fastidio, un'app che non si
/// apre è un disastro.
class FileCoachStore implements CoachStore {
  FileCoachStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const String fileName = 'kal-tracker-coach.json';

  final Future<Directory> Function() _directory;

  @override
  Future<CoachArchive> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return const CoachArchive.empty();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const CoachArchive.empty();
      }
      return CoachArchive.fromJson(decoded);
    } on Object {
      return const CoachArchive.empty();
    }
  }

  @override
  Future<void> write(CoachArchive archive) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(archive.toJson()), flush: true);
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

/// Store in memoria: per i test e per gli ambienti senza filesystem (i widget
/// test non hanno `path_provider`).
class InMemoryCoachStore implements CoachStore {
  InMemoryCoachStore([this._archive = const CoachArchive.empty()]);

  CoachArchive _archive;

  @override
  Future<CoachArchive> read() async => _archive;

  @override
  Future<void> write(CoachArchive archive) async => _archive = archive;
}

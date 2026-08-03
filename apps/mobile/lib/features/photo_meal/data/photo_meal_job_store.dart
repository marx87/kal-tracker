import 'dart:convert';
import 'dart:io';

import 'package:kal_tracker/features/photo_meal/domain/photo_meal_job.dart';
import 'package:path_provider/path_provider.dart';

/// Persistenza locale dei job foto in corso, sul pattern di
/// `FileBackupStorage`: file JSON in Application Support, letture difensive.
abstract class PhotoMealJobStore {
  Future<List<PhotoMealJob>> readJobs();

  Future<void> writeJobs(List<PhotoMealJob> jobs);
}

class FilePhotoMealJobStore implements PhotoMealJobStore {
  FilePhotoMealJobStore({Future<Directory> Function()? stateDirectory})
    : _stateDirectory = stateDirectory ?? getApplicationSupportDirectory;

  static const String stateFileName = 'kal-tracker-photo-jobs.json';

  final Future<Directory> Function() _stateDirectory;

  @override
  Future<List<PhotoMealJob>> readJobs() async {
    try {
      final file = await _stateFile();
      if (!file.existsSync()) {
        return const [];
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const [];
      }
      final rawJobs = decoded['jobs'];
      if (rawJobs is! List) {
        return const [];
      }
      return [for (final raw in rawJobs) ?PhotoMealJob.fromJson(raw)];
    } on Object {
      // File assente, corrotto o plugin non disponibile (test widget):
      // nessun job noto, il server resta la fonte di verità.
      return const [];
    }
  }

  @override
  Future<void> writeJobs(List<PhotoMealJob> jobs) async {
    try {
      final file = await _stateFile();
      await file.writeAsString(
        jsonEncode({
          'jobs': [for (final job in jobs) job.toJson()],
        }),
        flush: true,
      );
    } on Object {
      // Best effort come per lo stato dei backup: al prossimo avvio i job
      // pendenti si possono comunque rileggere dal server.
      return;
    }
  }

  Future<File> _stateFile() async {
    final directory = await _stateDirectory();
    return File('${directory.path}/$stateFileName');
  }
}

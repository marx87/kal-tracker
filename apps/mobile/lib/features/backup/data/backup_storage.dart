import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/backup/domain/backup_document.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

class BackupExportResult {
  const BackupExportResult({
    required this.path,
    required this.exportedAt,
    required this.shared,
    this.reason,
  });

  final String path;
  final DateTime exportedAt;
  final bool shared;
  final String? reason;
}

class BackupState {
  const BackupState({this.lastExportAt, this.lastExportPath});

  const BackupState.empty() : lastExportAt = null, lastExportPath = null;

  final DateTime? lastExportAt;
  final String? lastExportPath;
}

/// Chi apre il selettore di sistema. È un parametro perché
/// `FilePicker.pickFile` passa da un canale nativo che nei test non esiste:
/// iniettandolo si prova per davvero cosa succede al file scelto.
typedef BackupFilePicker = Future<PlatformFile?> Function();

abstract class BackupStorage {
  Future<BackupExportResult> saveBackup({
    required String contents,
    required DateTime exportedAt,
  });

  Future<BackupState> readState();

  Future<String> readRestoreSource(String rawInput);

  /// Vero solo quando c'è davvero un selettore di sistema da aprire: il
  /// bottone «Sfoglia» compare solo allora.
  bool get canBrowse;

  /// Apre il selettore e restituisce il PERCORSO del file scelto, nella
  /// stessa forma che [readRestoreSource] accetta già — così la strada del
  /// percorso digitato a mano resta una sola, e il percorso scelto Marco lo
  /// vede scritto invece di doversi fidare.
  ///
  /// `null` se il selettore viene chiuso senza scegliere.
  Future<String?> browseRestoreSource();
}

class FileBackupStorage implements BackupStorage {
  FileBackupStorage({
    Future<Directory> Function()? exportDirectory,
    Future<Directory> Function()? stateDirectory,
    BackupFilePicker? picker,
  }) : _exportDirectory = exportDirectory ?? getTemporaryDirectory,
       _stateDirectory = stateDirectory ?? getApplicationSupportDirectory,
       _picker = picker ?? pickBackupFileWithSystemPicker;

  static const String stateFileName = 'kal-tracker-backup-state.json';
  static const int maximumRestoreBytes = 32 * 1024 * 1024;

  final Future<Directory> Function() _exportDirectory;
  final Future<Directory> Function() _stateDirectory;
  final BackupFilePicker _picker;

  @override
  Future<BackupExportResult> saveBackup({
    required String contents,
    required DateTime exportedAt,
  }) async {
    final directory = await _exportDirectory();
    final file = File('${directory.path}/${backupFileName(exportedAt)}');
    await file.writeAsString(contents, flush: true);
    await _writeState(
      BackupState(lastExportAt: exportedAt.toUtc(), lastExportPath: file.path),
    );
    final shared = await _share(file.path);
    return BackupExportResult(
      path: file.path,
      exportedAt: exportedAt.toUtc(),
      shared: shared.done,
      reason: shared.reason,
    );
  }

  @override
  Future<BackupState> readState() async {
    try {
      final file = await _stateFile();
      if (!file.existsSync()) {
        return const BackupState.empty();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const BackupState.empty();
      }
      final lastExportAt = decoded['last_export_at'];
      final lastExportPath = decoded['last_export_path'];
      return BackupState(
        lastExportAt: lastExportAt is String
            ? DateTime.tryParse(lastExportAt)?.toUtc()
            : null,
        lastExportPath: lastExportPath is String ? lastExportPath : null,
      );
    } on Object {
      return const BackupState.empty();
    }
  }

  @override
  Future<String> readRestoreSource(String rawInput) async {
    final value = rawInput.trim();
    if (value.isEmpty) {
      throw const BackupFormatException(
        'Serve il contenuto del backup oppure il percorso del file.',
      );
    }
    if (value.startsWith('{')) {
      return value;
    }
    final file = File(value);
    if (!file.existsSync()) {
      throw BackupFormatException('Non trovo nessun file in «$value».');
    }
    if (await file.length() > maximumRestoreBytes) {
      throw const BackupFormatException('Il file di backup è troppo grande.');
    }
    return file.readAsString();
  }

  @override
  bool get canBrowse => true;

  @override
  Future<String?> browseRestoreSource() async {
    final PlatformFile? picked;
    try {
      picked = await _picker();
    } on Object catch (error) {
      // Selettore assente o negato: qui deve uscire una frase leggibile, non
      // un'eccezione di piattaforma.
      throw BackupFormatException(
        'Non riesco ad aprire il selettore di file: $error',
      );
    }
    if (picked == null) {
      return null;
    }
    final path = picked.path;
    if (path == null) {
      // Su Android e iOS il plugin copia sempre il file in cache e un
      // percorso c'è: se non c'è, meglio dirlo e lasciare la strada manuale
      // che fingere di aver preso qualcosa.
      throw BackupFormatException(
        'Non riesco a leggere «${picked.name}»: incolla il percorso del file '
        'o il suo contenuto.',
      );
    }
    return path;
  }

  static String backupFileName(DateTime exportedAt) {
    final day = AppTime.inRome(exportedAt);
    final month = day.month.toString().padLeft(2, '0');
    final dayOfMonth = day.day.toString().padLeft(2, '0');
    return 'kal-tracker-backup-${day.year}-$month-$dayOfMonth.json';
  }

  Future<File> _stateFile() async {
    final directory = await _stateDirectory();
    return File('${directory.path}/$stateFileName');
  }

  Future<void> _writeState(BackupState state) async {
    try {
      final file = await _stateFile();
      await file.writeAsString(
        jsonEncode({
          'last_export_at': state.lastExportAt?.toUtc().toIso8601String(),
          'last_export_path': state.lastExportPath,
        }),
        flush: true,
      );
    } on Object {
      return;
    }
  }

  Future<({bool done, String? reason})> _share(String path) async {
    try {
      final result = await OpenFile.open(path, type: 'application/json');
      final done = result.type == ResultType.done;
      return (done: done, reason: done ? null : result.message);
    } on Object catch (error) {
      return (done: false, reason: '$error');
    }
  }
}

/// Il selettore vero.
///
/// Nessun filtro per estensione di proposito: su Android i JSON scaricati
/// arrivano con tipi MIME assortiti e filtrando si vedrebbe grigio proprio il
/// backup che serve. Che dentro ci sia un backup valido lo dice poi il
/// controllo del checksum, con una frase in italiano.
Future<PlatformFile?> pickBackupFileWithSystemPicker() =>
    FilePicker.pickFile(dialogTitle: 'Scegli il file di backup');

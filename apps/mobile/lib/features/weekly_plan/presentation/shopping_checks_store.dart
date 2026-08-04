import 'dart:convert';
import 'dart:io';

import 'package:kal_tracker/features/weekly_plan/domain/shopping_checks.dart';
import 'package:path_provider/path_provider.dart';

/// Spunte della spesa su file JSON nella cartella di supporto dell'app.
///
/// Stesso patto di FileWaterSettingsStore e FileBackupStorage: letture
/// indulgenti (un file rovinato vale «nessuna spunta», mai un crash) e
/// scritture best-effort (se il disco fa i capricci la sessione continua
/// con lo stato in memoria).
class FileShoppingChecksStore implements ShoppingChecksStore {
  FileShoppingChecksStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const String fileName = 'kal-tracker-shopping-checks.json';

  final Future<Directory> Function() _directory;

  @override
  Future<ShoppingChecks> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return const ShoppingChecks.empty();
      }
      return ShoppingChecks.fromJson(jsonDecode(await file.readAsString()));
    } on Object {
      return const ShoppingChecks.empty();
    }
  }

  @override
  Future<void> write(ShoppingChecks checks) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(checks.toJson()), flush: true);
    } on Object {
      return;
    }
  }

  Future<File> _file() async {
    final directory = await _directory();
    return File('${directory.path}/$fileName');
  }
}

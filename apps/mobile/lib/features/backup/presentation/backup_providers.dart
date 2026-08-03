import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/backup/data/backup_repository.dart';
import 'package:kal_tracker/features/backup/data/backup_storage.dart';
import 'package:kal_tracker/features/backup/domain/backup_document.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:package_info_plus/package_info_plus.dart';

final backupRepositoryProvider = Provider<BackupRepository>(
  (ref) => BackupRepository(ref.watch(databaseProvider)),
);

final backupStorageProvider = Provider<BackupStorage>(
  (ref) => FileBackupStorage(),
);

final backupStateProvider = FutureProvider<BackupState>(
  (ref) => ref.watch(backupStorageProvider).readState(),
);

final backupAppVersionProvider = FutureProvider<String>((ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    return '${info.version}+${info.buildNumber}';
  } on Object {
    return BackupDocument.unknownAppVersion;
  }
});

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/updates/ota_manifest.dart';
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class UpdateDownloadResult {
  const UpdateDownloadResult({
    required this.path,
    required this.installerOpened,
    this.reason,
  });

  final String path;
  final bool installerOpened;
  final String? reason;
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => 'UpdateException: $message';
}

class UpdateService {
  static const _maximumManifestBytes = 64 * 1024;

  UpdateService({required this.config, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(minutes: 3),
            ),
          );

  final AppConfig config;
  final Dio _dio;

  Future<AndroidUpdateManifest?> checkForUpdate() async {
    if (!Platform.isAndroid || !config.hasOtaConfiguration) {
      return null;
    }

    final manifestUri = Uri.tryParse(config.otaManifestUrl);
    if (manifestUri == null ||
        manifestUri.scheme != 'https' ||
        manifestUri.host.toLowerCase() != 'github.com' ||
        !manifestUri.path.startsWith(
          '/marx87/kal-tracker-releases/releases/latest/download/',
        )) {
      throw const UpdateException('indirizzo del manifest OTA non autorizzato');
    }

    final response = await _dio.get<List<int>>(
      manifestUri.toString(),
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw const UpdateException('manifest OTA vuoto');
    }
    if (bytes.length > _maximumManifestBytes) {
      throw const UpdateException('manifest OTA troppo grande');
    }

    final manifest = await OtaManifestVerifier.fromBase64(
      config.otaPublicKeyBase64,
      expectedKeyId: config.otaKeyId,
    ).verify(bytes);
    final packageInfo = await PackageInfo.fromPlatform();

    if (manifest.applicationId != packageInfo.packageName) {
      throw const UpdateException('application ID del manifest non valido');
    }
    if (manifest.channel != config.otaChannel) {
      throw const UpdateException('canale OTA non valido');
    }

    final installedBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
    return manifest.buildNumber > installedBuild ? manifest : null;
  }

  Future<UpdateDownloadResult> downloadAndInstall(
    AndroidUpdateManifest manifest, {
    required ValueChanged<double> onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw const UpdateException(
        'installazione OTA disponibile solo su Android',
      );
    }
    manifest.validateAssetUrl();

    final directory =
        await getExternalStorageDirectory() ??
        await getApplicationSupportDirectory();
    final file = File('${directory.path}/kal-tracker-update.apk');
    if (await file.exists()) {
      await file.delete();
    }

    try {
      await _downloadWithRetry(
        manifest.assetUrl.toString(),
        file.path,
        onProgress,
      );
      await _verifyFile(file, manifest);
      return _openInstaller(file.path);
    } on Object {
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    }
  }

  Future<void> _downloadWithRetry(
    String url,
    String path,
    ValueChanged<double> onProgress,
  ) async {
    const attempts = 3;
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        await _dio.download(
          url,
          path,
          deleteOnError: true,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              onProgress(received / total);
            }
          },
        );
        return;
      } on DioException catch (error) {
        lastError = error;
        final status = error.response?.statusCode;
        final retryable =
            error.type == DioExceptionType.connectionError ||
            error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.receiveTimeout ||
            (status != null && status >= 500);
        if (!retryable || attempt == attempts) {
          break;
        }
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
    throw UpdateException('download APK fallito: $lastError');
  }

  Future<void> _verifyFile(File file, AndroidUpdateManifest manifest) async {
    if (await file.length() != manifest.sizeBytes) {
      throw const UpdateException('dimensione APK inattesa');
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString().toLowerCase() != manifest.sha256) {
      throw const UpdateException('checksum SHA-256 APK non corrispondente');
    }
  }

  Future<UpdateDownloadResult> _openInstaller(String path) async {
    final result = await OpenFile.open(
      path,
      type: 'application/vnd.android.package-archive',
    );
    return UpdateDownloadResult(
      path: path,
      installerOpened: result.type == ResultType.done,
      reason: result.type == ResultType.done ? null : result.message,
    );
  }
}

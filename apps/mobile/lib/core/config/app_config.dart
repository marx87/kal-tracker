import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.otaManifestUrl,
    required this.otaPublicKeyBase64,
    required this.otaKeyId,
    required this.otaChannel,
  });

  const AppConfig.fromEnvironment()
    : supabaseUrl = const String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey = const String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
      otaManifestUrl = const String.fromEnvironment(
        'OTA_MANIFEST_URL',
        defaultValue:
            'https://github.com/marx87/kal-tracker-releases/'
            'releases/latest/download/kal-tracker-update.json',
      ),
      otaPublicKeyBase64 = const String.fromEnvironment(
        'OTA_PUBLIC_KEY_BASE64',
      ),
      otaKeyId = const String.fromEnvironment(
        'OTA_KEY_ID',
        defaultValue: 'ota-2026-01',
      ),
      otaChannel = const String.fromEnvironment(
        'OTA_CHANNEL',
        defaultValue: 'personal',
      );

  const AppConfig.offline()
    : supabaseUrl = '',
      supabasePublishableKey = '',
      otaManifestUrl = '',
      otaPublicKeyBase64 = '',
      otaKeyId = 'ota-2026-01',
      otaChannel = 'personal';

  final String supabaseUrl;
  final String supabasePublishableKey;
  final String otaManifestUrl;
  final String otaPublicKeyBase64;
  final String otaKeyId;
  final String otaChannel;

  bool get hasSupabaseConfiguration =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;

  bool get hasOtaConfiguration =>
      otaManifestUrl.isNotEmpty &&
      otaPublicKeyBase64.isNotEmpty &&
      otaKeyId.isNotEmpty;
}

final appConfigProvider = Provider<AppConfig>(
  (ref) => const AppConfig.fromEnvironment(),
);

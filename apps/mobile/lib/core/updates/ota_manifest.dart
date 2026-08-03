import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class OtaManifestException implements Exception {
  const OtaManifestException(this.message);

  final String message;

  @override
  String toString() => 'OtaManifestException: $message';
}

class AndroidUpdateManifest {
  const AndroidUpdateManifest({
    required this.applicationId,
    required this.channel,
    required this.version,
    required this.buildNumber,
    required this.minimumSupportedBuild,
    required this.tag,
    required this.assetUrl,
    required this.sha256,
    required this.sizeBytes,
    required this.notes,
    required this.publishedAt,
    required this.sourceRepository,
    required this.sourceCommit,
  });

  factory AndroidUpdateManifest.fromPayload(Map<String, Object?> json) {
    final platform = _requiredString(json, 'platform');
    if (platform != 'android') {
      throw const OtaManifestException('piattaforma OTA non valida');
    }

    final sha256 = _requiredString(json, 'sha256').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const OtaManifestException('SHA-256 non valido');
    }

    final version = _requiredString(json, 'version');
    if (!RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
    ).hasMatch(version)) {
      throw const OtaManifestException('versione OTA non valida');
    }

    final buildNumber = _requiredPositiveInt(json, 'buildNumber');
    final minimumSupportedBuild = _requiredPositiveInt(
      json,
      'minimumSupportedBuild',
    );
    if (minimumSupportedBuild > buildNumber) {
      throw const OtaManifestException('build minima OTA non valida');
    }

    final tag = _requiredString(json, 'tag');
    if (tag != 'v$version-b$buildNumber') {
      throw const OtaManifestException('tag OTA non coerente');
    }

    final publishedAt = DateTime.tryParse(_requiredString(json, 'publishedAt'));
    if (publishedAt == null || !publishedAt.isUtc) {
      throw const OtaManifestException('data di pubblicazione non valida');
    }

    final sourceRepository = _requiredString(json, 'sourceRepository');
    if (sourceRepository != 'marx87/kal-tracker') {
      throw const OtaManifestException('repository sorgente non valido');
    }
    final sourceCommit = _requiredString(json, 'sourceCommit').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(sourceCommit)) {
      throw const OtaManifestException('commit sorgente non valido');
    }

    final manifest = AndroidUpdateManifest(
      applicationId: _requiredString(json, 'applicationId'),
      channel: _requiredString(json, 'channel'),
      version: version,
      buildNumber: buildNumber,
      minimumSupportedBuild: minimumSupportedBuild,
      tag: tag,
      assetUrl: Uri.parse(_requiredString(json, 'assetUrl')),
      sha256: sha256,
      sizeBytes: _requiredPositiveInt(json, 'sizeBytes'),
      notes: _requiredString(json, 'notes'),
      publishedAt: publishedAt.toUtc(),
      sourceRepository: sourceRepository,
      sourceCommit: sourceCommit,
    );
    manifest.validateAssetUrl();
    return manifest;
  }

  final String applicationId;
  final String channel;
  final String version;
  final int buildNumber;
  final int minimumSupportedBuild;
  final String tag;
  final Uri assetUrl;
  final String sha256;
  final int sizeBytes;
  final String notes;
  final DateTime publishedAt;
  final String sourceRepository;
  final String sourceCommit;

  void validateAssetUrl() {
    final expectedUrl =
        'https://github.com/marx87/kal-tracker-releases/releases/download/'
        '$tag/kal-tracker-$tag.apk';
    if (assetUrl.scheme != 'https' ||
        assetUrl.host.toLowerCase() != 'github.com' ||
        assetUrl.hasPort ||
        assetUrl.hasQuery ||
        assetUrl.hasFragment ||
        assetUrl.toString() != expectedUrl) {
      throw const OtaManifestException('indirizzo APK non autorizzato');
    }
    const maximumApkBytes = 300 * 1024 * 1024;
    if (sizeBytes > maximumApkBytes) {
      throw const OtaManifestException('APK OTA troppo grande');
    }
  }
}

class OtaManifestVerifier {
  OtaManifestVerifier({
    required List<int> publicKeyBytes,
    required this.expectedKeyId,
  }) : _publicKey = SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519) {
    if (publicKeyBytes.length != 32) {
      throw const OtaManifestException(
        'la chiave pubblica Ed25519 deve essere di 32 byte',
      );
    }
  }

  factory OtaManifestVerifier.fromBase64(
    String value, {
    required String expectedKeyId,
  }) => OtaManifestVerifier(
    publicKeyBytes: _decodeBase64(value, field: 'chiave pubblica'),
    expectedKeyId: expectedKeyId,
  );

  final SimplePublicKey _publicKey;
  final String expectedKeyId;

  Future<AndroidUpdateManifest> verify(List<int> envelopeBytes) async {
    final Object? decodedEnvelope;
    try {
      decodedEnvelope = jsonDecode(utf8.decode(envelopeBytes));
    } on Object {
      throw const OtaManifestException('envelope JSON non valido');
    }
    if (decodedEnvelope is! Map<String, Object?>) {
      throw const OtaManifestException('envelope OTA non valido');
    }

    if (decodedEnvelope['schema'] != 1) {
      throw const OtaManifestException('schema OTA non supportato');
    }
    if (_requiredString(decodedEnvelope, 'keyId') != expectedKeyId) {
      throw const OtaManifestException('chiave OTA non riconosciuta');
    }
    final payloadBytes = _decodeBase64(
      _requiredString(decodedEnvelope, 'payload'),
      field: 'payload',
    );
    final signatureBytes = _decodeBase64(
      _requiredString(decodedEnvelope, 'signature'),
      field: 'firma',
    );
    if (signatureBytes.length != 64) {
      throw const OtaManifestException('firma Ed25519 non valida');
    }

    final valid = await Ed25519().verify(
      payloadBytes,
      signature: Signature(signatureBytes, publicKey: _publicKey),
    );
    if (!valid) {
      throw const OtaManifestException('firma OTA non valida');
    }

    final Object? decodedPayload;
    try {
      decodedPayload = jsonDecode(utf8.decode(payloadBytes));
    } on Object {
      throw const OtaManifestException('payload OTA non valido');
    }
    if (decodedPayload is! Map<String, Object?>) {
      throw const OtaManifestException('payload OTA non valido');
    }
    return AndroidUpdateManifest.fromPayload(decodedPayload);
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw OtaManifestException('campo $key mancante o non valido');
  }
  return value;
}

int _requiredPositiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value <= 0) {
    throw OtaManifestException('campo $key mancante o non valido');
  }
  return value;
}

Uint8List _decodeBase64(String value, {required String field}) {
  try {
    final normalized = value.replaceAll('-', '+').replaceAll('_', '/');
    final padding = '=' * ((4 - normalized.length % 4) % 4);
    return base64Decode('$normalized$padding');
  } on FormatException {
    throw OtaManifestException('$field in Base64 non valido');
  }
}

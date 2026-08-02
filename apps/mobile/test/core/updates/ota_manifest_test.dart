import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/updates/ota_manifest.dart';

void main() {
  final payload = <String, Object?>{
    'applicationId': 'it.marcomartelli.kaltracker',
    'platform': 'android',
    'channel': 'personal',
    'version': '1.2.0',
    'buildNumber': 12,
    'minimumSupportedBuild': 1,
    'tag': 'v1.2.0-b12',
    'assetUrl':
        'https://github.com/marx87/kal-tracker-releases/'
        'releases/download/v1.2.0-b12/kal-tracker-v1.2.0-b12.apk',
    'sha256': 'a' * 64,
    'sizeBytes': 123456,
    'notes': 'Primo aggiornamento',
    'publishedAt': '2026-08-02T12:00:00Z',
    'sourceRepository': 'marx87/kal-tracker',
    'sourceCommit': 'a' * 40,
  };

  test('accetta un manifest Ed25519 valido', () async {
    final signed = await _signPayload(payload);
    final manifest = await OtaManifestVerifier(
      publicKeyBytes: signed.publicKey,
      expectedKeyId: 'test-key',
    ).verify(signed.envelope);

    expect(manifest.applicationId, 'it.marcomartelli.kaltracker');
    expect(manifest.buildNumber, 12);
    expect(manifest.assetUrl.host, 'github.com');
  });

  test('rifiuta un payload modificato dopo la firma', () async {
    final signed = await _signPayload(payload);
    final envelope = jsonDecode(utf8.decode(signed.envelope)) as Map;
    envelope['payload'] = _base64Url(
      utf8.encode(jsonEncode({...payload, 'buildNumber': 99})),
    );

    expect(
      () => OtaManifestVerifier(
        publicKeyBytes: signed.publicKey,
        expectedKeyId: 'test-key',
      ).verify(utf8.encode(jsonEncode(envelope))),
      throwsA(isA<OtaManifestException>()),
    );
  });

  test('rifiuta asset fuori dal repository consentito', () {
    expect(
      () => AndroidUpdateManifest.fromPayload({
        ...payload,
        'assetUrl': 'https://example.com/kal-tracker.apk',
      }),
      throwsA(isA<OtaManifestException>()),
    );
  });

  test('rifiuta un key ID inatteso', () async {
    final signed = await _signPayload(payload);

    expect(
      () => OtaManifestVerifier(
        publicKeyBytes: signed.publicKey,
        expectedKeyId: 'ota-2026-01',
      ).verify(signed.envelope),
      throwsA(isA<OtaManifestException>()),
    );
  });
}

Future<({List<int> envelope, List<int> publicKey})> _signPayload(
  Map<String, Object?> payload,
) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final payloadBytes = utf8.encode(jsonEncode(payload));
  final signature = await algorithm.sign(payloadBytes, keyPair: keyPair);
  final envelope = utf8.encode(
    jsonEncode({
      'schema': 1,
      'keyId': 'test-key',
      'payload': _base64Url(payloadBytes),
      'signature': _base64Url(signature.bytes),
    }),
  );
  return (envelope: envelope, publicKey: publicKey.bytes);
}

String _base64Url(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

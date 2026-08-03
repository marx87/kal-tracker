import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kal_tracker/features/photo_meal/domain/photo_pipeline.dart';

void main() {
  test('ridimensiona il lato lungo a 1280 mantenendo le proporzioni', () {
    final processed = MealPhotoPipeline.process(_jpegBytes(1600, 1200));

    expect(processed.width, 1280);
    expect(processed.height, 960);
    final decoded = img.decodeImage(processed.bytes)!;
    expect(decoded.width, 1280);
    expect(decoded.height, 960);
  });

  test('una foto verticale si riduce sul lato lungo', () {
    final processed = MealPhotoPipeline.process(_jpegBytes(1200, 1600));

    expect(processed.width, 960);
    expect(processed.height, 1280);
  });

  test('le foto già piccole non vengono ingrandite', () {
    final processed = MealPhotoPipeline.process(_jpegBytes(640, 480));

    expect(processed.width, 640);
    expect(processed.height, 480);
  });

  test('la ricodifica elimina i marker EXIF dal file caricato', () {
    final original = _withFakeExif(_jpegBytes(1600, 1200));
    expect(_containsExifMarker(original), isTrue);

    final processed = MealPhotoPipeline.process(original);

    expect(_containsExifMarker(processed.bytes), isFalse);
  });

  test('produce un JPEG entro i limiti del contratto con sha256 coerente', () {
    final original = _jpegBytes(2000, 1500, quality: 95);
    final processed = MealPhotoPipeline.process(original);

    // Magic bytes JPEG, come li verifica il worker.
    expect(processed.bytes.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    expect(processed.mimeType, 'image/jpeg');
    expect(processed.sizeBytes, processed.bytes.length);
    expect(
      processed.sizeBytes,
      lessThanOrEqualTo(MealPhotoPipeline.maxUploadBytes),
    );
    // La riduzione + qualità 80 deve alleggerire davvero il file.
    expect(processed.sizeBytes, lessThan(original.length));
    // Hex minuscolo (il CHECK remoto rifiuta le maiuscole) e coerente
    // con i byte finali.
    expect(processed.sha256Hex, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(processed.sha256Hex, sha256.convert(processed.bytes).toString());
  });

  test('rifiuta byte che non sono un\'immagine', () {
    expect(
      () => MealPhotoPipeline.process(Uint8List.fromList(List.filled(64, 7))),
      throwsA(isA<PhotoPipelineException>()),
    );
  });

  test('rifiuta una foto vuota', () {
    expect(
      () => MealPhotoPipeline.process(Uint8List(0)),
      throwsA(isA<PhotoPipelineException>()),
    );
  });
}

Uint8List _jpegBytes(int width, int height, {int quality = 92}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 7) % 256, (y * 5) % 256, (x + y) % 256);
    }
  }
  return img.encodeJpg(image, quality: quality);
}

/// Inserisce dopo il SOI un segmento APP1 EXIF con una voce reale
/// (Make = "Kal"): se la pipeline non ripulisse i metadati, l'encoder
/// li riscriverebbe nel file finale.
Uint8List _withFakeExif(Uint8List jpeg) {
  final payload = <int>[
    ...'Exif'.codeUnits, 0x00, 0x00,
    // Header TIFF little-endian, IFD0 a offset 8.
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00,
    // IFD0: una voce.
    0x01, 0x00,
    // Tag 0x010F (Make), tipo ASCII, 4 byte inline: "Kal\0".
    0x0F, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x4B, 0x61, 0x6C, 0x00,
    // Nessun IFD successivo.
    0x00, 0x00, 0x00, 0x00,
  ];
  final length = payload.length + 2;
  return Uint8List.fromList([
    ...jpeg.sublist(0, 2),
    0xFF,
    0xE1,
    (length >> 8) & 0xFF,
    length & 0xFF,
    ...payload,
    ...jpeg.sublist(2),
  ]);
}

bool _containsExifMarker(Uint8List bytes) {
  const needle = [0x45, 0x78, 0x69, 0x66]; // 'Exif'
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var found = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        found = false;
        break;
      }
    }
    if (found) {
      return true;
    }
  }
  return false;
}

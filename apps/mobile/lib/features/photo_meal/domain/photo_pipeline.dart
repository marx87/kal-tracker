import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

class PhotoPipelineException implements Exception {
  const PhotoPipelineException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Foto del pasto già pronta per l'upload: ridotta, ricodificata JPEG e
/// senza metadati. sha256 e dimensione sono calcolati sui byte FINALI,
/// gli stessi che finiranno sullo Storage (il worker verifica l'identità
/// esatta byte per byte).
class ProcessedMealPhoto {
  const ProcessedMealPhoto({
    required this.bytes,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.sha256Hex,
  });

  final Uint8List bytes;
  final String mimeType;
  final int width;
  final int height;

  /// Hex minuscolo: il CHECK remoto `^[0-9a-f]{64}$` rifiuta le maiuscole.
  final String sha256Hex;

  int get sizeBytes => bytes.length;
}

/// Pipeline PURA di preparazione della foto: decodifica, orientamento,
/// riduzione del lato lungo e ricodifica JPEG. La ricodifica riparte dai
/// soli pixel, quindi EXIF/GPS non lasciano mai il telefono (regola 9);
/// per sicurezza i metadati vengono comunque azzerati prima dell'encode.
abstract final class MealPhotoPipeline {
  static const String mimeType = 'image/jpeg';
  static const int maxLongSidePx = 1280;
  static const int jpegQuality = 80;

  /// Limite del bucket e del CHECK su image_size_bytes (10 MiB).
  static const int maxUploadBytes = 10 * 1024 * 1024;

  static ProcessedMealPhoto process(Uint8List original) {
    if (original.isEmpty) {
      throw const PhotoPipelineException(
        'La foto è vuota: riprova a scattarla.',
      );
    }
    final decoded = img.decodeImage(original);
    if (decoded == null) {
      throw const PhotoPipelineException(
        'Non riesco a leggere questa foto: serve un JPEG, PNG o WebP.',
      );
    }
    // Applica l'orientamento EXIF ai pixel, così la rotazione sopravvive
    // anche dopo che i metadati sono stati buttati via.
    var working = img.bakeOrientation(decoded);
    final longSide = working.width > working.height
        ? working.width
        : working.height;
    if (longSide > maxLongSidePx) {
      working = working.width >= working.height
          ? img.copyResize(
              working,
              width: maxLongSidePx,
              interpolation: img.Interpolation.linear,
            )
          : img.copyResize(
              working,
              height: maxLongSidePx,
              interpolation: img.Interpolation.linear,
            );
    }
    // Niente EXIF/GPS nel file caricato: l'encoder JPEG riscriverebbe i
    // metadati presenti sull'immagine decodificata.
    working.exif = img.ExifData();
    final encoded = img.encodeJpg(working, quality: jpegQuality);
    if (encoded.length > maxUploadBytes) {
      throw const PhotoPipelineException(
        'La foto resta troppo pesante anche dopo la riduzione.',
      );
    }
    return ProcessedMealPhoto(
      bytes: encoded,
      mimeType: mimeType,
      width: working.width,
      height: working.height,
      sha256Hex: sha256.convert(encoded).toString(),
    );
  }
}

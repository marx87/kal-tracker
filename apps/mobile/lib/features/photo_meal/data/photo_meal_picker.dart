import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:kal_tracker/features/photo_meal/domain/photo_meal_job.dart';

/// Scatta o sceglie la foto con image_picker. Ritorna null se Marco annulla.
/// `requestFullMetadata: false` evita fin dall'origine EXIF/GPS su iOS;
/// la pipeline ricodifica comunque i soli pixel prima dell'upload.
Future<Uint8List?> pickMealPhotoWithImagePicker(PhotoMealSource source) async {
  final picker = ImagePicker();
  final file = await picker.pickImage(
    source: source == PhotoMealSource.camera
        ? ImageSource.camera
        : ImageSource.gallery,
    maxWidth: 2048,
    maxHeight: 2048,
    requestFullMetadata: false,
  );
  if (file == null) {
    return null;
  }
  return file.readAsBytes();
}

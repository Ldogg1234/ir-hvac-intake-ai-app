import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../constants/collections.dart';

/// Firebase Storage uploads for the HVAC media warehouse.
class MediaService {
  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Upload a picked file to the warehouse and return its download URL.
  /// [type] should be 'photos' or 'videos'.
  Future<String?> uploadMedia(
    XFile file, {
    required String brand,
    required String model,
    required String type,
  }) async {
    try {
      final filename =
          '${DateTime.now().millisecondsSinceEpoch}_${file.name}';
      final path = StoragePaths.warehouseMedia(
        brand: brand.isNotEmpty ? brand : 'Unknown',
        model: model.isNotEmpty ? model : 'Unknown',
        type: type,
        filename: filename,
      );

      final ref = _storage.ref().child(path);
      final bytes = await file.readAsBytes();
      final task = ref.putData(bytes);
      final snapshot = await task;
      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      debugPrint('MediaService.uploadMedia error: $e');
      return null;
    }
  }

  /// Upload multiple files and return the list of download URLs (nulls skipped).
  Future<List<String>> uploadMany(
    List<XFile> files, {
    required String brand,
    required String model,
    required String type,
  }) async {
    final urls = <String>[];
    for (final file in files) {
      final url = await uploadMedia(file,
          brand: brand, model: model, type: type);
      if (url != null) urls.add(url);
    }
    return urls;
  }
}

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;

class FirebaseService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Uploads a file to Firebase Storage and returns the download URL.
  /// Categorizes by brand and model to build the Troubleshooting Data Warehouse.
  Future<String?> uploadMedia(XFile file, String brand, String model, String type) async {
    try {
      final String fileName = '${DateTime.now().millisecondsSinceEpoch}_${file.name}';
      final String path = 'warehouse/$brand/$model/$type/$fileName';
      
      final Reference ref = _storage.ref().child(path);
      
      // On web, picked files use a blob URL, so we need bytes
      final bytes = await file.readAsBytes();
      final UploadTask uploadTask = ref.putData(bytes);
      
      final TaskSnapshot snapshot = await uploadTask;
      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      debugPrint('Error uploading media: $e');
      return null;
    }
  }

  /// Saves a complete tech report to Firestore.
  Future<void> saveReport({
    required String notes,
    required String observations,
    required String brand,
    required String faultCode,
    required List<String> mediaUrls,
    required String summary,
    double? latitude,
    double? longitude,
  }) async {
    try {
      await _firestore.collection('reports').add({
        'timestamp': FieldValue.serverTimestamp(),
        'notes': notes,
        'observations': observations,
        'brand': brand,
        'faultCode': faultCode,
        'mediaUrls': mediaUrls,
        'summary': summary,
        'location': latitude != null && longitude != null 
            ? GeoPoint(latitude, longitude) 
            : null,
      });
    } catch (e) {
      debugPrint('Error saving report to Firestore: $e');
      rethrow;
    }
  }
}

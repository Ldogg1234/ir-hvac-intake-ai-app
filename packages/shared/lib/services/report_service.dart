import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../constants/collections.dart';
import '../models/report.dart';

/// Firestore reads and writes for the `reports` collection.
/// Report docs use the lead's ID as their document ID.
class ReportService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _reports =>
      _db.collection(FirestoreCollections.reports);

  /// Fetch the full report for a given lead.
  Future<Report?> getReportForLead(String leadId) async {
    try {
      final doc = await _reports.doc(leadId).get();
      if (!doc.exists || doc.data() == null) return null;
      return Report.fromJson(doc.data()!, leadId: leadId);
    } catch (e) {
      debugPrint('ReportService.getReportForLead error: $e');
      return null;
    }
  }

  /// Stream of a report doc — useful for the diagnostic engine to react
  /// in real-time as the intake app or Cloud Functions update a report.
  Stream<Report?> watchReport(String leadId) {
    return _reports.doc(leadId).snapshots().map((doc) {
      if (!doc.exists || doc.data() == null) return null;
      return Report.fromJson(doc.data()!, leadId: leadId);
    });
  }

  /// Save or overwrite a legacy flat report (used by the old saveReport path).
  Future<void> saveRawReport({
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
      await _reports.add({
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
      debugPrint('ReportService.saveRawReport error: $e');
      rethrow;
    }
  }
}

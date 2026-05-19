import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../models/professional_report.dart';

/// Wraps all Firebase Cloud Function callables.
/// One place to track every function name across both apps.
class CloudFunctionsService {
  final FirebaseFunctions _fn = FirebaseFunctions.instance;

  HttpsCallable _call(String name) => _fn.httpsCallable(name);

  // ── Intake ────────────────────────────────────────────────────────────────

  /// Submit a new intake lead through the backend pipeline.
  Future<void> submitIntake(Map<String, dynamic> payload) async {
    try {
      await _call('submitIntake').call(payload);
    } catch (e) {
      debugPrint('CF submitIntake error: $e');
      rethrow;
    }
  }

  // ── Dispatch ──────────────────────────────────────────────────────────────

  /// Assign a tech + trigger calendar/notification side-effects.
  Future<bool> assignTech({
    required String leadId,
    required String techEmail,
    required String techName,
    required DateTime scheduledTime,
    String clientName = 'N/A',
    String propertyAddress = 'N/A',
    String clientPhone = 'N/A',
    String notes = 'No notes provided',
  }) async {
    try {
      await _call('assignTech').call({
        'leadId': leadId,
        'techEmail': techEmail,
        'techName': techName,
        'scheduledTime': scheduledTime.toIso8601String(),
        'clientName': clientName,
        'propertyAddress': propertyAddress,
        'clientPhone': clientPhone,
        'notes': notes,
      });
      return true;
    } catch (e) {
      debugPrint('CF assignTech error: $e');
      return false;
    }
  }

  // ── Tech field actions ────────────────────────────────────────────────────

  /// Start navigation for a job; returns the navigation URL or null.
  Future<String?> techStartNavigation(String leadId) async {
    try {
      final result = await _call('techStartNavigation').call({'leadId': leadId});
      if (result.data['success'] == true) {
        return result.data['navigationUrl'] as String?;
      }
    } catch (e) {
      debugPrint('CF techStartNavigation error: $e');
    }
    return null;
  }

  /// Clock in at a job site.
  Future<bool> techClockIn(String leadId, double lat, double lng) async {
    try {
      final result = await _call('techClockIn').call({
        'leadId': leadId,
        'lat': lat,
        'lng': lng,
      });
      return result.data['success'] == true;
    } catch (e) {
      debugPrint('CF techClockIn error: $e');
      return false;
    }
  }

  /// Finalize and submit a tech report (transitions status to report-submitted).
  Future<bool> techSubmitReport(String leadId) async {
    try {
      final result =
          await _call('techSubmitReport').call({'leadId': leadId});
      return result.data['success'] == true;
    } catch (e) {
      debugPrint('CF techSubmitReport error: $e');
      return false;
    }
  }

  // ── Report / AI ───────────────────────────────────────────────────────────

  /// Generate a professional AI report from raw technician notes.
  Future<ProfessionalReport?> getProfessionalReport(String notes) async {
    try {
      final result =
          await _call('getProfessionalReport').call({'notes': notes});
      if (result.data != null) {
        return ProfessionalReport.fromJson(
            Map<String, dynamic>.from(result.data as Map));
      }
    } catch (e) {
      debugPrint('CF getProfessionalReport error: $e');
    }
    return null;
  }

  /// Fetch the full report + lead context for Nicole's review screen.
  Future<Map<String, dynamic>?> getReportForReview(String leadId) async {
    try {
      final result =
          await _call('getReportForReview').call({'leadId': leadId});
      return result.data as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('CF getReportForReview error: $e');
      return null;
    }
  }

  /// Generate a branded PDF for a report; returns the download URL.
  Future<String?> generatePdfReport(String leadId) async {
    try {
      final result =
          await _call('generatePdfReport').call({'leadId': leadId});
      if (result.data['success'] == true) {
        return result.data['pdfUrl'] as String?;
      }
    } catch (e) {
      debugPrint('CF generatePdfReport error: $e');
    }
    return null;
  }
}

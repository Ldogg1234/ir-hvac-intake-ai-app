import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show debugPrint;

class ProfessionalReport {
  final String executiveSummary;
  final String systemFindings;
  final List<String> recommendations;
  final String safetyNotes;

  ProfessionalReport({
    required this.executiveSummary,
    required this.systemFindings,
    required this.recommendations,
    required this.safetyNotes,
  });

  factory ProfessionalReport.fromJson(Map<String, dynamic> json) {
    return ProfessionalReport(
      executiveSummary: json['executiveSummary'] as String? ?? '',
      systemFindings: json['systemFindings'] as String? ?? '',
      recommendations: (json['recommendations'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      safetyNotes: json['safetyNotes'] as String? ?? '',
    );
  }
}

class GenerativeAiService {
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Calls the Gemini-powered Cloud Function to rewrite technician notes.
  Future<ProfessionalReport?> generateProfessionalReport(String notes) async {
    try {
      final HttpsCallable callable = _functions.httpsCallable('getProfessionalReport');
      final result = await callable.call({'notes': notes});
      
      if (result.data != null) {
        return ProfessionalReport.fromJson(Map<String, dynamic>.from(result.data));
      }
    } catch (e) {
      debugPrint('Error generating professional report: $e');
    }
    return null;
  }
}

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show debugPrint;

class TechnicalReadings {
  final double gasPressure;      // in WC
  final double staticPressure;   // in WC
  final double tempRise;        // in F
  final String status;          // "Normal", "Warning", "Critical"

  TechnicalReadings({
    required this.gasPressure,
    required this.staticPressure,
    required this.tempRise,
    required this.status,
  });

  factory TechnicalReadings.fromJson(Map<String, dynamic> json) {
    return TechnicalReadings(
      gasPressure: (json['gasPressure'] ?? 0.0).toDouble(),
      staticPressure: (json['staticPressure'] ?? 0.0).toDouble(),
      tempRise: (json['tempRise'] ?? 0.0).toDouble(),
      status: json['status'] ?? 'Normal',
    );
  }
}

class ProfessionalReport {
  final String executiveSummary;
  final String systemFindings;
  final List<String> recommendations;
  final String safetyNotes;
  final TechnicalReadings? readings;

  ProfessionalReport({
    required this.executiveSummary,
    required this.systemFindings,
    required this.recommendations,
    required this.safetyNotes,
    this.readings,
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
      readings: json['readings'] != null 
          ? TechnicalReadings.fromJson(Map<String, dynamic>.from(json['readings']))
          : null,
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

  /// Cleans up raw voice dictation into professional clinical sentences.
  Future<String?> cleanDictation(String rawText) async {
    try {
      final HttpsCallable callable = _functions.httpsCallable('cleanDictation');
      final result = await callable.call({'text': rawText});
      return result.data['cleanedText'] as String?;
    } catch (e) {
      debugPrint('Error cleaning dictation: $e');
    }
    return rawText;
  }


  /// Searches manuals and diagnostic video catalog using natural language.
  Future<AskTylerResponse> askTyler(String query) async {
    try {
      final HttpsCallable callable = _functions.httpsCallable('searchDiagnosticVideos');
      final result = await callable.call({'query': query});
      
      if (result.data['success'] == true) {
        final List<dynamic> results = result.data['videos'] ?? [];
        final videos = results.map((e) => DiagnosticVideo.fromJson(Map<String, dynamic>.from(e))).toList();
        final String answer = result.data['answer'] ?? "I couldn't find an answer right now.";
        return AskTylerResponse(answer: answer, videos: videos);
      }
    } catch (e) {
      debugPrint('Error asking Tyler: $e');
    }
    return AskTylerResponse(answer: "I'm having trouble connecting right now.", videos: []);
  }
}

class DiagnosticVideo {
  final String id;
  final String youtubeUrl;
  final String description;
  final String type;

  DiagnosticVideo({
    required this.id,
    required this.youtubeUrl,
    required this.description,
    required this.type,
  });

  factory DiagnosticVideo.fromJson(Map<String, dynamic> json) {
    return DiagnosticVideo(
      id: json['id'] ?? '',
      youtubeUrl: json['youtube_url'] ?? '',
      description: json['description'] ?? '',
      type: json['type'] ?? 'unknown',
    );
  }
}

class AskTylerResponse {
  final String answer;
  final List<DiagnosticVideo> videos;

  AskTylerResponse({required this.answer, required this.videos});
}

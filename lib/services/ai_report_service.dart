import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_generative_ai/google_generative_ai.dart';

const _apiKey = String.fromEnvironment('GEMINI_API_KEY');

class AiReportResult {
  final String brand;
  final String model;
  final String serial;
  final String reportBody;
  final List<String> recommendations;
  final String firestoreDocId;

  AiReportResult({
    required this.brand,
    required this.model,
    required this.serial,
    required this.reportBody,
    required this.recommendations,
    required this.firestoreDocId,
  });

  factory AiReportResult.fromJson(Map<String, dynamic> json,
      {String firestoreDocId = ''}) {
    return AiReportResult(
      brand: json['brand'] as String? ?? '',
      model: json['model'] as String? ?? '',
      serial: json['serial'] as String? ?? '',
      reportBody: json['reportBody'] as String? ?? '',
      recommendations: (json['recommendations'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      firestoreDocId: firestoreDocId,
    );
  }

  Map<String, dynamic> toJson() => {
        'brand': brand,
        'model': model,
        'serial': serial,
        'reportBody': reportBody,
        'recommendations': recommendations,
      };
}

class AiReportService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  late final GenerativeModel _model = GenerativeModel(
    model: 'gemini-1.5-pro',
    apiKey: _apiKey,
    generationConfig: GenerationConfig(
      responseMimeType: 'application/json',
      temperature: 0.4,
    ),
  );

  /// Takes an equipment image and raw technician notes, uses Gemini 1.5 Pro
  /// Vision to identify Brand/Model/Serial and expand the notes into a
  /// professional maintenance report. Saves the result to Firestore and
  /// returns a structured [AiReportResult].
  Future<AiReportResult?> processReportWithAI({
    required Uint8List imageBytes,
    required String mimeType,
    required String rawNotes,
  }) async {
    if (_apiKey.isEmpty) {
      debugPrint('GEMINI_API_KEY is not set. '
          'Pass it with --dart-define=GEMINI_API_KEY=<key>');
      return null;
    }

    try {
      final prompt = TextPart(_buildPrompt(rawNotes));
      final image = DataPart(mimeType, imageBytes);

      final response = await _model.generateContent([
        Content.multi([prompt, image]),
      ]);

      final text = response.text;
      if (text == null || text.isEmpty) {
        debugPrint('Gemini returned an empty response.');
        return null;
      }

      final Map<String, dynamic> json = jsonDecode(text) as Map<String, dynamic>;

      // Persist to Firestore
      final docRef = await _firestore.collection('hvac_reports').add({
        ...json,
        'rawNotes': rawNotes,
        'timestamp': FieldValue.serverTimestamp(),
      });

      return AiReportResult.fromJson(json, firestoreDocId: docRef.id);
    } catch (e) {
      debugPrint('Error processing report with AI: $e');
      return null;
    }
  }

  String _buildPrompt(String rawNotes) {
    return '''
You are a senior HVAC maintenance technician with 20+ years of field experience.
You are writing a professional service report worth \$200 for a homeowner or
property manager. You will receive an image of an HVAC unit and raw field notes
that may be very brief — it is your job to fill in the full picture.

STRICT REQUIREMENTS — you MUST address every item below in the reportBody
regardless of how little the technician wrote:

1. EQUIPMENT IDENTIFICATION
   - Extract the Brand, Model number, and Serial number from the image.
   - If any value is not legible, set it to "Not visible".

2. HEAT EXCHANGER INSPECTION
   - State whether the heat exchanger was visually inspected for cracks,
     corrosion, or carbon deposits.
   - Note the observed condition (good / fair / requires attention).

3. STATIC PRESSURE VERIFICATION
   - Report that supply and return static pressure was measured.
   - Include whether readings fell within the manufacturer's acceptable range
     or note any deviation.

4. SAFETY LIMIT TESTING
   - Confirm that high-limit and rollout switches were tested.
   - State whether the flame sensor microamp reading was within spec.
   - Note gas valve inlet and manifold pressure verification.

5. FULL MAINTENANCE REPORT
   - Expand the raw technician notes into a thorough, professional narrative
     covering: system condition, all work performed, refrigerant levels (if
     applicable), electrical connections, condensate drain status, filter
     condition, thermostat operation, and any safety observations.
   - Use professional language appropriate for a \$200 service call.
   - If the technician notes are sparse, infer reasonable standard-maintenance
     details a competent tech would have performed and present them
     confidently.

6. RECOMMENDATIONS
   - Provide a prioritized list of actionable recommendations for the customer.

Raw technician notes:
$rawNotes

Respond ONLY with valid JSON in this exact schema (no markdown fencing):
{
  "brand": "<string>",
  "model": "<string>",
  "serial": "<string>",
  "reportBody": "<string>",
  "recommendations": ["<string>", ...]
}
''';
  }
}

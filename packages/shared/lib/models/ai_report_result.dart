/// Result from the Gemini Vision AI report processor.
/// Stored in the `hvac_reports` Firestore collection.
class AiReportResult {
  final String brand;
  final String model;
  final String serial;
  final String reportBody;
  final List<String> recommendations;
  final String firestoreDocId;

  const AiReportResult({
    required this.brand,
    required this.model,
    required this.serial,
    required this.reportBody,
    required this.recommendations,
    required this.firestoreDocId,
  });

  factory AiReportResult.fromJson(
    Map<String, dynamic> json, {
    String firestoreDocId = '',
  }) {
    return AiReportResult(
      brand: json['brand'] as String? ?? '',
      model: json['model'] as String? ?? '',
      serial: json['serial'] as String? ?? '',
      reportBody: json['reportBody'] as String? ?? '',
      recommendations: (json['recommendations'] as List<dynamic>?)
              ?.map((e) => e.toString())
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

/// Live field readings captured during a service call.
class TechnicalReadings {
  final double gasPressure;    // in WC
  final double staticPressure; // in WC
  final double tempRise;       // in °F
  final String status;         // 'Normal' | 'Warning' | 'Critical'

  const TechnicalReadings({
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
      status: json['status'] as String? ?? 'Normal',
    );
  }

  Map<String, dynamic> toJson() => {
        'gasPressure': gasPressure,
        'staticPressure': staticPressure,
        'tempRise': tempRise,
        'status': status,
      };
}

/// AI-generated professional report structure (returned by getProfessionalReport CF).
class ProfessionalReport {
  final String executiveSummary;
  final String systemFindings;
  final List<String> recommendations;
  final String safetyNotes;
  final TechnicalReadings? readings;

  const ProfessionalReport({
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
              ?.map((e) => e.toString())
              .toList() ??
          [],
      safetyNotes: json['safetyNotes'] as String? ?? '',
      readings: json['readings'] != null
          ? TechnicalReadings.fromJson(
              Map<String, dynamic>.from(json['readings'] as Map))
          : null,
    );
  }
}

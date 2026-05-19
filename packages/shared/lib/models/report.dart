import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a report document from the `reports` Firestore collection.
/// Each report doc uses the lead's ID as its document ID.
class Report {
  final String leadId;
  final String executiveSummary;
  final String systemFindings;
  final List<String> recommendations;
  final String safetyNotes;
  final List<TechnicalMetric> technicalMetrics;
  final EquipmentId? equipmentId;
  final String reviewStatus; // 'pending' | 'approved'
  final String? pdfUrl;
  final List<String> inspectionPhotoUrls;
  final DateTime? timestamp;

  const Report({
    required this.leadId,
    required this.executiveSummary,
    required this.systemFindings,
    required this.recommendations,
    required this.safetyNotes,
    required this.technicalMetrics,
    this.equipmentId,
    required this.reviewStatus,
    this.pdfUrl,
    required this.inspectionPhotoUrls,
    this.timestamp,
  });

  factory Report.fromJson(Map<String, dynamic> data, {required String leadId}) {
    return Report(
      leadId: leadId,
      executiveSummary: data['executiveSummary'] as String? ?? '',
      systemFindings: data['systemFindings'] as String? ?? '',
      recommendations: (data['recommendations'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      safetyNotes: data['safetyNotes'] as String? ?? '',
      technicalMetrics: (data['technicalMetrics'] as List<dynamic>?)
              ?.map((e) =>
                  TechnicalMetric.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          [],
      equipmentId: data['equipmentId'] != null
          ? EquipmentId.fromJson(
              Map<String, dynamic>.from(data['equipmentId'] as Map))
          : null,
      reviewStatus: data['reviewStatus'] as String? ?? 'pending',
      pdfUrl: data['pdfUrl'] as String?,
      inspectionPhotoUrls:
          (data['inspectionPhotoUrls'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [],
      timestamp: data['timestamp'] is Timestamp
          ? (data['timestamp'] as Timestamp).toDate()
          : null,
    );
  }
}

/// A single technical reading row (used in gauges / tables).
class TechnicalMetric {
  final String metric;
  final String value;
  final String unit;
  final String status; // 'safe' | 'warning' | 'dangerous'
  final String recommended;
  final String? sourcePhotoUrl;

  const TechnicalMetric({
    required this.metric,
    required this.value,
    required this.unit,
    required this.status,
    required this.recommended,
    this.sourcePhotoUrl,
  });

  factory TechnicalMetric.fromJson(Map<String, dynamic> json) {
    return TechnicalMetric(
      metric: json['metric'] as String? ?? '',
      value: json['value'] as String? ?? '',
      unit: json['unit'] as String? ?? '',
      status: json['status'] as String? ?? 'safe',
      recommended: json['recommended'] as String? ?? '',
      sourcePhotoUrl: json['sourcePhotoUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'metric': metric,
        'value': value,
        'unit': unit,
        'status': status,
        'recommended': recommended,
        if (sourcePhotoUrl != null) 'sourcePhotoUrl': sourcePhotoUrl,
      };
}

/// Equipment identification block.
class EquipmentId {
  final String brand;
  final String model;
  final String serial;
  final String? age;
  final String? refrigerant;

  const EquipmentId({
    required this.brand,
    required this.model,
    required this.serial,
    this.age,
    this.refrigerant,
  });

  factory EquipmentId.fromJson(Map<String, dynamic> json) {
    return EquipmentId(
      brand: json['brand'] as String? ?? '',
      model: json['model'] as String? ?? '',
      serial: json['serial'] as String? ?? '',
      age: json['age'] as String?,
      refrigerant: json['refrigerant'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'brand': brand,
        'model': model,
        'serial': serial,
        if (age != null) 'age': age,
        if (refrigerant != null) 'refrigerant': refrigerant,
      };
}

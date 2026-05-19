import 'package:cloud_firestore/cloud_firestore.dart';
import '../constants/lead_status.dart';

/// Represents a lead document from the `leads` Firestore collection.
class Lead {
  final String id;
  final String propertyAddress;
  final String jobType;
  final List<String> jobCategories;
  final String clientName;
  final String clientCell;
  final String clientEmail;
  final LeadStatus status;
  final String? technicianEmail;
  final String? technicianName;
  final DateTime? scheduledTime;
  final DateTime? scheduledAt;
  final String? visitRequested;
  final ActiveTimer? activeTimer;
  final DateTime? createdAt;

  const Lead({
    required this.id,
    required this.propertyAddress,
    required this.jobType,
    required this.jobCategories,
    required this.clientName,
    required this.clientCell,
    required this.clientEmail,
    required this.status,
    this.technicianEmail,
    this.technicianName,
    this.scheduledTime,
    this.scheduledAt,
    this.visitRequested,
    this.activeTimer,
    this.createdAt,
  });

  factory Lead.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return Lead.fromJson(data, id: doc.id);
  }

  factory Lead.fromJson(Map<String, dynamic> data, {required String id}) {
    DateTime? parseTime(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is String) return DateTime.tryParse(v);
      return null;
    }

    return Lead(
      id: id,
      propertyAddress: data['property_address'] as String? ?? '',
      jobType: data['job_type'] as String? ?? '',
      jobCategories: (data['job_categories'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      clientName: data['client_name'] as String? ?? '',
      clientCell: data['client_cell'] as String? ?? '',
      clientEmail: data['client_email'] as String? ?? '',
      status: LeadStatus.fromString(data['status'] as String?),
      technicianEmail: data['technician_email'] as String?,
      technicianName: data['technician_name'] as String?,
      scheduledTime: parseTime(data['scheduled_time']),
      scheduledAt: parseTime(data['scheduled_at']),
      visitRequested: data['visit_requested'] as String?,
      activeTimer: data['active_timer'] != null
          ? ActiveTimer.fromJson(
              Map<String, dynamic>.from(data['active_timer'] as Map))
          : null,
      createdAt: parseTime(data['created_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'property_address': propertyAddress,
        'job_type': jobType,
        'job_categories': jobCategories,
        'client_name': clientName,
        'client_cell': clientCell,
        'client_email': clientEmail,
        'status': status.value,
        if (technicianEmail != null) 'technician_email': technicianEmail,
        if (technicianName != null) 'technician_name': technicianName,
        if (scheduledTime != null)
          'scheduled_time': scheduledTime!.toIso8601String(),
        if (visitRequested != null) 'visit_requested': visitRequested,
      };
}

/// Timer state embedded in a lead doc (drive or labor).
class ActiveTimer {
  final String type; // 'drive' | 'labor'
  final DateTime? startedAt;

  const ActiveTimer({required this.type, this.startedAt});

  factory ActiveTimer.fromJson(Map<String, dynamic> json) {
    DateTime? start;
    if (json['started_at'] is Timestamp) {
      start = (json['started_at'] as Timestamp).toDate();
    }
    return ActiveTimer(
      type: json['type'] as String? ?? '',
      startedAt: start,
    );
  }
}

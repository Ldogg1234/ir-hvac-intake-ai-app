import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../constants/collections.dart';
import '../constants/lead_status.dart';
import '../models/lead.dart';

/// Firestore reads and writes for the `leads` collection.
class LeadService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _leads =>
      _db.collection(FirestoreCollections.leads);

  // ── Streams ──────────────────────────────────────────────────────────────

  /// Assigned jobs for a specific technician (tech app home screen).
  Stream<List<Lead>> watchAssignedJobs(String? email) {
    if (email == null) return const Stream.empty();
    return _leads
        .where('technician_email', isEqualTo: email.toLowerCase())
        .snapshots()
        .map((s) => s.docs.map((d) => Lead.fromDoc(d)).toList());
  }

  /// Leads in intake status (admin dashboard intake queue).
  Stream<List<Lead>> watchIntakeLeads() {
    return _leads
        .where('status', isEqualTo: LeadStatus.intake.value)
        .snapshots()
        .map((s) => s.docs.map((d) => Lead.fromDoc(d)).toList());
  }

  /// Dispatched / active leads (admin dispatch board).
  Stream<List<Lead>> watchScheduledLeads() {
    return _leads
        .where('status', whereIn: [
          LeadStatus.assigned.value,
          LeadStatus.scheduled.value,
          LeadStatus.inProgress.value,
          LeadStatus.reportSubmitted.value,
        ])
        .snapshots()
        .map((s) => s.docs.map((d) => Lead.fromDoc(d)).toList());
  }

  /// Leads awaiting Nicole's review (report-submitted).
  Stream<List<Lead>> watchReportsForReview() {
    return _leads
        .where('status', isEqualTo: LeadStatus.reportSubmitted.value)
        .snapshots()
        .map((s) => s.docs.map((d) => Lead.fromDoc(d)).toList());
  }

  // ── Reads ────────────────────────────────────────────────────────────────

  /// Fetch a single lead by ID.
  Future<Lead?> getLead(String leadId) async {
    try {
      final doc = await _leads.doc(leadId).get();
      if (!doc.exists) return null;
      return Lead.fromDoc(doc);
    } catch (e) {
      debugPrint('LeadService.getLead error: $e');
      return null;
    }
  }

  // ── Writes ───────────────────────────────────────────────────────────────

  /// Directly update a lead's status.
  Future<void> updateStatus(String leadId, LeadStatus status) async {
    await _leads.doc(leadId).update({'status': status.value});
  }

  /// Assign a technician to a lead (Firestore side only;
  /// call [CloudFunctionsService.assignTech] for the full pipeline).
  Future<void> assignTech({
    required String leadId,
    required String techEmail,
    required String techName,
    required DateTime scheduledTime,
  }) async {
    try {
      await _leads.doc(leadId).update({
        'technician_email': techEmail.toLowerCase(),
        'technician_name': techName,
        'status': LeadStatus.assigned.value,
        'scheduled_at': FieldValue.serverTimestamp(),
        'scheduled_time': scheduledTime.toIso8601String(),
      });
    } catch (e) {
      debugPrint('LeadService.assignTech error: $e');
      rethrow;
    }
  }
}

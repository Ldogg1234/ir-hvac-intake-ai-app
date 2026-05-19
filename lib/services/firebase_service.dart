import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'dart:convert';
class FirebaseService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Uploads a file to Firebase Storage and returns the download URL.
  /// Categorizes by brand and model to build the Troubleshooting Data Warehouse.
  Future<String?> uploadMedia(XFile file, String brand, String model, String type) async {
    try {
      final String fileName = '${DateTime.now().millisecondsSinceEpoch}_${file.name}';
      final String path = 'warehouse/$brand/$model/$type/$fileName';
      
      final Reference ref = _storage.ref().child(path);
      
      // On web, picked files use a blob URL, so we need bytes
      final bytes = await file.readAsBytes();
      final UploadTask uploadTask = ref.putData(bytes);
      
      final TaskSnapshot snapshot = await uploadTask;
      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      debugPrint('Error uploading media: $e');
      return null;
    }
  }

  /// Saves a complete tech report to Firestore.
  Future<void> saveReport({
    String? leadId,
    String? reportType,
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
      final reportData = {
        'timestamp': FieldValue.serverTimestamp(),
        'reportType': reportType,
        'notes': notes,
        'observations': observations,
        'brand': brand,
        'faultCode': faultCode,
        'mediaUrls': mediaUrls,
        'summary': summary,
        'location': latitude != null && longitude != null 
            ? GeoPoint(latitude, longitude) 
            : null,
      };

      if (leadId != null && leadId.isNotEmpty) {
        await _firestore.collection('reports').doc(leadId).set(reportData, SetOptions(merge: true));
        await techSubmitReport(leadId);
      } else {
        await _firestore.collection('reports').add(reportData);
      }
    } catch (e) {
      debugPrint('Error saving report to Firestore: $e');
      rethrow;
    }
  }
  Future<String?> _resolveLeadId(String idOrEventId) async {
    try {
      final doc = await _firestore.collection('leads').doc(idOrEventId).get();
      if (doc.exists) return idOrEventId;
      
      final query = await _firestore.collection('leads').where('calendar_event_id', isEqualTo: idOrEventId).limit(1).get();
      if (query.docs.isNotEmpty) return query.docs.first.id;
    } catch (e) {
      debugPrint('Error resolving lead id: $e');
    }
    return null;
  }

  /// Assigns a technician to a lead via Cloud Functions.
  Future<bool> assignTech({
    required String leadId,
    required String techEmail,
    required String techName,
    required DateTime scheduledTime,
  }) async {
    try {
      final actualLeadId = await _resolveLeadId(leadId);
      if (actualLeadId == null) {
        debugPrint('Cannot assign tech: Lead not found for ID/EventID $leadId');
        return false;
      }

      // Fetch lead data for detailed payload
      final leadDoc = await _firestore.collection('leads').doc(actualLeadId).get();
      final leadData = leadDoc.data() ?? {};

      final techData = leadData['technician_email'];
      List<String> updatedEmails = [];
      if (techData is String && techData.isNotEmpty) {
        updatedEmails = techData.split(',').map((e) => e.trim().toLowerCase()).toList();
      } else if (techData is List) {
        updatedEmails = techData.map((e) => e.toString().toLowerCase()).toList();
      }
      if (!updatedEmails.contains(techEmail.toLowerCase())) {
        updatedEmails.add(techEmail.toLowerCase());
      }

      // Direct Firestore update as requested (God View sync)
      await _firestore.collection('leads').doc(actualLeadId).update({
        'technician_email': updatedEmails.join(','),
        'technician_name': techName, // QBO Sync will override this with joined names
        'status': 'assigned',
        'scheduled_at': FieldValue.serverTimestamp(),
        'scheduled_time': scheduledTime.toIso8601String(),
      });

      // Maintain Cloud Function call for backend side-effects (calendar/notification)
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('assignTech');
      await callable.call({
        'leadId': actualLeadId,
        'techEmail': techEmail,
        'techName': techName,
        'scheduledTime': scheduledTime.toIso8601String(),
        'clientName': leadData['client_name'] ?? 'N/A',
        'propertyAddress': leadData['property_address'] ?? 'N/A',
        'clientPhone': leadData['client_cell'] ?? 'N/A',
        'notes': leadData['visit_requested'] ?? 'No notes provided',
        'callerEmail': FirebaseAuth.instance.currentUser?.email ?? 'admin@immediateresponsehvac.ca',
      });
      return true;
    } catch (e) {
      debugPrint('Error assigning tech: $e');
      return true; // Return true if Firestore succeeded even if Function failed
    }
  }

  /// Removes a technician from a lead via Cloud Functions.
  Future<bool> removeTech({
    required String leadId,
    required String techEmail,
  }) async {
    try {
      final actualLeadId = await _resolveLeadId(leadId);
      if (actualLeadId == null) return false;

      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('removeTech');
      await callable.call({
        'leadId': actualLeadId,
        'techEmail': techEmail,
        'callerEmail': FirebaseAuth.instance.currentUser?.email ?? 'admin@immediateresponsehvac.ca',
      });
      return true;
    } catch (e) {
      debugPrint('Error removing tech: $e');
      return false;
    }
  }

  /// Completely unschedules an event and returns it to unassigned
  Future<bool> unscheduleEvent({
    required String leadId,
  }) async {
    try {
      final actualLeadId = await _resolveLeadId(leadId);
      if (actualLeadId == null) return false;

      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('unscheduleEvent');
      await callable.call({
        'leadId': actualLeadId,
        'callerEmail': FirebaseAuth.instance.currentUser?.email ?? 'admin@immediateresponsehvac.ca',
      });
      return true;
    } catch (e) {
      debugPrint('Error unscheduling event: $e');
      return false;
    }
  }

  /// Reschedules an event (drag and drop resizing or moving)
  Future<bool> rescheduleEvent({
    required String leadId,
    required DateTime startTime,
    required DateTime endTime,
    String? recurrenceRule,
  }) async {
    try {
      final actualLeadId = await _resolveLeadId(leadId);
      if (actualLeadId == null) return false;

      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('rescheduleEvent');
      await callable.call({
        'leadId': actualLeadId,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        if (recurrenceRule != null) 'recurrenceRule': recurrenceRule,
        'callerEmail': FirebaseAuth.instance.currentUser?.email ?? 'admin@immediateresponsehvac.ca',
      });
      return true;
    } catch (e) {
      debugPrint('Error rescheduling event: $e');
      return false;
    }
  }

  /// Starts navigation for a tech and pings the backend.
  Future<String?> startNavigation(String leadId) async {
    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('techStartNavigation');
      final result = await callable.call({'leadId': leadId});
      
      if (result.data['success'] == true) {
        return result.data['navigationUrl'] as String?;
      }
    } catch (e) {
      debugPrint('Error starting navigation: $e');
    }
    return null;
  }

  /// Records arrival at the job site (triggers Labor Time).
  Future<bool> techClockIn(String leadId, double lat, double lng) async {
    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('techClockIn');
      final result = await callable.call({
        'leadId': leadId,
        'lat': lat,
        'lng': lng,
      });
      return result.data['success'] == true;
    } catch (e) {
      debugPrint('Error clocking in: $e');
      return false;
    }
  }

  /// Fetches assigned jobs for a technician.
  Stream<QuerySnapshot> getAssignedJobs(String? email) {
    return _firestore
        .collection('leads')
        .where('technician_email', isEqualTo: email?.toLowerCase())
        .snapshots();
  }

  /// Fetches scheduled/assigned leads for the dispatch board.
  Stream<QuerySnapshot> getScheduledLeads() {
    return _firestore
        .collection('leads')
        .where('status', whereIn: [
          'assigned', 'scheduled', 'in-progress', 'report-submitted', 'to-be-scheduled', 
          'waiting-for-report', 'report-arrived', 'report-sent', 'quote-to-be-sent', 'quote-sent'
        ])
        .snapshots();
  }

  /// Fetches new, unassigned intake leads.
  Stream<QuerySnapshot> getIntakeLeads() {
    return _firestore
        .collection('leads')
        .where('status', isEqualTo: 'intake')
        .snapshots();
  }

  /// Fetches all active leads for the OPS Lead Management dashboard.
  Stream<QuerySnapshot> getOpsManagementLeads() {
    return _firestore
        .collection('leads')
        .where('status', whereIn: [
          'intake', 'to-be-scheduled', 'quote-to-be-sent', 
          'assigned', 'scheduled', 'in-progress', 
          'waiting-for-report', 'report-submitted', 'report-arrived', 'report-sent',
          'quote-sent'
        ])
        .snapshots();
  }

  /// Fetches native Google Calendar events via HTTP endpoint.
  Future<List<Map<String, dynamic>>> getGoogleCalendarEvents() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return [];
      
      final token = await user.getIdToken();
      if (token == null) return [];
      final url = Uri.parse('https://us-central1-immediate-response-ai-b18b8.cloudfunctions.net/getTechCalendar?viewAll=true&raw=true');
      
      final response = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'X-Firebase-Id-Token': token,
        },
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          return List<Map<String, dynamic>>.from(data['events'] ?? []);
        }
      } else {
        debugPrint('Failed to load Google Calendar events: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error fetching Google Calendar events: $e');
    }
    return [];
  }

  // ============================================
  // Visual Reporting Engine — Nicole's Review
  // ============================================

  /// Fetches leads with status 'report-submitted' for Nicole's Review Dashboard.
  /// Each lead will have a corresponding doc in the 'reports' collection
  /// containing technicalMetrics, equipmentId, and reviewStatus.
  Stream<QuerySnapshot> getReportsForReview() {
    return _firestore
        .collection('leads')
        .where('status', isEqualTo: 'report-submitted')
        .snapshots();
  }

  /// Finalizes the technician report and transitions status.
  Future<bool> techSubmitReport(String leadId) async {
    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('techSubmitReport');
      final result = await callable.call({'leadId': leadId});
      return result.data['success'] == true;
    } catch (e) {
      debugPrint('Error submitting report: $e');
      return false;
    }
  }

  /// Fetches the full report (with technicalMetrics) for a specific lead.
  /// The report doc in Firestore contains:
  ///   - executiveSummary: String
  ///   - systemFindings: String
  ///   - recommendations: List<String>
  ///   - safetyNotes: String
  ///   - technicalMetrics: List<Map> with keys:
  ///       metric, value, unit, status (safe/warning/dangerous),
  ///       recommended, sourcePhotoUrl
  ///   - equipmentId: Map with keys: brand, model, serial, age, refrigerant
  ///   - reviewStatus: 'pending' | 'approved'
  ///   - pdfUrl: String? (set after PDF generation)
  ///   - inspectionPhotoUrls: List<String>
  Future<Map<String, dynamic>?> getReportForLead(String leadId) async {
    try {
      final doc = await _firestore.collection('reports').doc(leadId).get();
      return doc.data();
    } catch (e) {
      debugPrint('Error fetching report for lead $leadId: $e');
      return null;
    }
  }

  /// Calls the Cloud Function to get the full report + lead context.
  /// Returns the report data with technicalMetrics for chart rendering.
  Future<Map<String, dynamic>?> getReportForReviewCallable(String leadId) async {
    try {
      final HttpsCallable callable =
          FirebaseFunctions.instance.httpsCallable('getReportForReview');
      final result = await callable.call({'leadId': leadId});
      return result.data as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('Error calling getReportForReview: $e');
      return null;
    }
  }

  /// Generates a branded PDF for a report (Ops only).
  /// Returns the download URL of the generated PDF.
  Future<String?> generatePdfReport(String leadId) async {
    try {
      final HttpsCallable callable =
          FirebaseFunctions.instance.httpsCallable('generatePdfReport');
      final result = await callable.call({'leadId': leadId});
      if (result.data['success'] == true) {
        return result.data['pdfUrl'] as String?;
      }
    } catch (e) {
      debugPrint('Error generating PDF: $e');
    }
    return null;
  }
  /// Creates a mock lead for testing purposes (now calls the backend pipeline).
  Future<void> createTestLead() async {
    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('submitIntake');
      await callable.call({
        'property_address': '123 HVAC Lane, Toronto, ON',
        'job_type': 'Residential',
        'job_categories': ['Troubleshooting - HVAC'],
        'client_name': 'Test Client ${DateTime.now().millisecondsSinceEpoch}',
        'client_cell': '555-0199',
        'client_email': 'test-client@immediateresponsehvac.ca',
        'visit_requested': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
        'visit_status': 'To Be Scheduled',
      });
    } catch (e) {
      debugPrint('Error creating test lead: $e');
    }
  }

  /// Manually retry missing background tasks for a lead (Drive, Calendar, QBO).
  Future<bool> retryLeadIntake(String leadId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('Cannot retry intake: No user signed in');
        return false;
      }
      
      final token = await user.getIdToken();
      final url = Uri.parse('https://us-central1-immediate-response-ai-b18b8.cloudfunctions.net/retryIntake');
      
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'lead_id': leadId,
        }),
      );
      
      if (response.statusCode == 200) {
        debugPrint('Retry successful: ${response.body}');
        return true;
      } else {
        debugPrint('Retry failed with status ${response.statusCode}: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('Error retrying lead intake: $e');
      return false;
    }
  }

  /// Initializes a manual inspection (no calendar event).
  /// Creates Drive folder and project record.
  Future<Map<String, dynamic>?> manualIntake({
    required String propertyAddress,
    required String claimRef,
    required String technicianEmail,
  }) async {
    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('manualIntake');
      final result = await callable.call({
        'propertyAddress': propertyAddress,
        'claimRef': claimRef,
        'technicianEmail': technicianEmail,
      });
      return result.data as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('Error in manualIntake: $e');
      return null;
    }
  }

  /// Fetches address suggestions from Google Places API via Cloud Function.
  Future<Map<String, dynamic>> autocompleteAddress(String query) async {
    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('autocompleteAddress');
      final result = await callable.call({'query': query});
      return result.data as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Error in autocompleteAddress: $e');
      return {'predictions': []};
    }
  }

  /// Deletes a lead from Firestore.
  Future<void> deleteLead(String leadId) async {
    try {
      await _firestore.collection('leads').doc(leadId).delete();
      debugPrint('Successfully deleted lead $leadId');
    } catch (e) {
      debugPrint('Error deleting lead $leadId: $e');
    }
  }
}

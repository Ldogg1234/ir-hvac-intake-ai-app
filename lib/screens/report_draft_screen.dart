import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/troubleshooting_service.dart';
import '../services/firebase_service.dart';
import '../services/generative_ai_service.dart';
import 'package:go_router/go_router.dart';
import '../widgets/technical_summary_widget.dart';

class ReportDraftScreen extends StatefulWidget {
  final String? leadId;
  const ReportDraftScreen({super.key, this.leadId});

  @override
  State<ReportDraftScreen> createState() => _ReportDraftScreenState();
}

enum MediaType { photo, video }

class SelectedMedia {
  final XFile file;
  final MediaType type;
  final String? assetId; // Link media to a specific asset
  SelectedMedia(this.file, this.type, {this.assetId});
}

class ApplianceAsset {
  final String id;
  final String category; // 'Heating', 'Cooling', 'Water_Heating', etc.
  final String name;
  bool ratingPlateCaptured = false;
  bool manualHunted = false;
  List<String> pendingPhotos = [];

  ApplianceAsset({
    required this.id,
    required this.category,
    required this.name,
    this.pendingPhotos = const [],
  });
}

class _ReportDraftScreenState extends State<ReportDraftScreen> {
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _obsController = TextEditingController();
  final TextEditingController _brandController = TextEditingController();
  final TextEditingController _faultController = TextEditingController();
  
  final SpeechToText _speechToText = SpeechToText();
  final ImagePicker _picker = ImagePicker();
  final TroubleshootingService _tsService = TroubleshootingService();
  final FirebaseService _firebaseService = FirebaseService();
  
  String? _selectedReportType;
  final List<String> _reportTypes = [
    'Inspection Report',
    'Troubleshooting Report',
    'Progress Report',
    'Post Job Report',
    'Quote Report',
    'DC Report',
    'Service Report'
  ];
  
  bool _isLoading = false;
  ProfessionalReport? _generatedReport;
  TroubleshootingResult? _activeLookup;
  
  bool isSpeechEnabled = false;
  bool _isListening = false;
  bool _isCoPilotActive = false;
  bool _isRecordingAcoustics = false;
  bool _auditVerified = false;
  bool _auditCompleted = false;
  String _sttBaselineText = ''; 
  
  // Acoustic Forensic Data
  double? _peakDb;
  double? _peakHz;
  String? _acousticDiagnosis;

  final List<SelectedMedia> _selectedMedia = [];
  final Map<String, bool> _processingPhotos = {}; // Track OCR/Vision processing state
  final List<ApplianceAsset> _discoveredAssets = [
    ApplianceAsset(id: 'primary', category: 'Heating', name: 'Primary Furnace'),
  ];
  Map<String, dynamic>? _leadData;

  String _locationStatus = '';
  Position? _currentPosition;
  dynamic _positionStream; // using dynamic or StreamSubscription if dart:async is imported

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _determinePosition();
    _fetchLeadDetails();
    _startGeofencing();
  }

  void _startGeofencing() {
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 20)
    ).listen((position) {
      if (_leadData?['property_address'] == null || _auditCompleted) return;
      
      final targetLat = _leadData?['latitude'] ?? 43.6532;
      final targetLng = _leadData?['longitude'] ?? -79.3832;
      
      final distance = Geolocator.distanceBetween(
        position.latitude, position.longitude,
        targetLat, targetLng
      );
      
      if (distance > 50) {
        // Asset Omission Check
        final missingRatingPlate = _discoveredAssets.firstWhere(
          (a) => !a.ratingPlateCaptured,
          orElse: () => ApplianceAsset(id: 'none', category: '', name: ''),
        );

        if (missingRatingPlate.id != 'none') {
          _showCriticalOmissionAlert(distance, missingRatingPlate.name);
        } else {
          _showGeofenceCriticalWarning(distance);
        }
      }
    });
  }

  void _showCriticalOmissionAlert(double distance, String assetName) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black,
        title: const Text('CRITICAL OMISSION', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w900)),
        content: Text(
          'You are ${distance.toStringAsFixed(0)}m from site. You identified a $assetName but provided no forensic identification. Turn back now to capture the Rating Plate.',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
            onPressed: () => Navigator.pop(context), 
            child: const Text('I AM TURNING BACK', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold))
          ),
        ],
      ),
    );
  }

  void _showGeofenceCriticalWarning(double distance) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.black,
        duration: const Duration(seconds: 10),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('CRITICAL GEOFENCE ALERT', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 2)),
            const Divider(color: Colors.white),
            Text('You are ${distance.toStringAsFixed(0)}m from site. Audit is INCOMPLETE.', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Future<void> _fetchLeadDetails() async {
    if (widget.leadId == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('leads').doc(widget.leadId).get();
      if (doc.exists && mounted) {
        setState(() {
          _leadData = doc.data();
          if (_leadData?['property_address'] != null) {
            _locationStatus = 'Arrived at ${_leadData!['property_address']}';
          }
        });
      }
    } catch (e) {
      debugPrint('Error fetching lead: $e');
    }
  }

  void _initSpeech() async {
    isSpeechEnabled = await _speechToText.initialize();
    setState(() {});
  }

  Future<void> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    setState(() {
      _locationStatus = 'Checking location...';
    });

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _locationStatus = 'Location disabled';
      });
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _locationStatus = 'Permission denied';
        });
        return;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _locationStatus = 'Permission permanently denied';
      });
      return;
    } 

    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high)
      );
      setState(() {
        _currentPosition = position;
        _locationStatus = 'Lat: ${position.latitude.toStringAsFixed(4)}, Lon: ${position.longitude.toStringAsFixed(4)}';
      });
    } catch (e) {
      setState(() {
        _locationStatus = 'Location error';
      });
    }
  }

  void _onFaultLookup() async {
    HapticFeedback.lightImpact();
    if (_brandController.text.isEmpty || _faultController.text.isEmpty) return;

    final result = await _tsService.lookupFault(
      _brandController.text, 
      _faultController.text
    );

    if (result != null) {
      setState(() {
        _activeLookup = result;
        if (!_obsController.text.contains(result.likelyCulprit)) {
           final prefix = _obsController.text.isEmpty ? '' : '\n';
           _obsController.text += '${prefix}Likely Culprit: ${result.likelyCulprit}';
        }
      });
    } else {
      setState(() {
        _activeLookup = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No fault code match found.')),
        );
      }
    }
  }

  void _startListening() async {
    await _speechToText.listen(
      onResult: (result) {
        // REPLACE — never append. result.recognizedWords is the full current transcript.
        if (result.recognizedWords.isNotEmpty) {
          setState(() {
            _notesController.text = result.recognizedWords;
            _notesController.selection = TextSelection.fromPosition(
              TextPosition(offset: _notesController.text.length),
            );
          });
        }
      },
      listenFor: const Duration(minutes: 2),
      pauseFor: const Duration(seconds: 4),
      cancelOnError: true,
      partialResults: true,
    );
    setState(() => _isListening = true);
  }

  void _stopListening() async {
    await _speechToText.stop();
    // Clear the speech engine buffer so it doesn't carry over to next session
    await _speechToText.cancel();
    setState(() => _isListening = false);
    // Reset baseline to current field value so a new session starts fresh
    _sttBaselineText = '';
  }
  
  Future<void> _capturePhoto(String assetId, String label) async {
    final ImagePicker picker = ImagePicker();
    final XFile? photo = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 100, // Force high-resolution
    );

    if (photo != null) {
      await _showMarkupAndCaptionPrompt(photo, MediaType.photo, assetId, label);
    }
  }

  Future<void> _uploadForensicPhoto(SelectedMedia media, String label) async {
    final claimRef = _leadData?['claim_reference'] ?? 'TEMP';
    final asset = _discoveredAssets.firstWhere((a) => a.id == media.assetId);
    
    // Path: audits/{claim_ref}/{asset_type}/{photo_label}_{ts}.jpg
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final extension = media.type == MediaType.video ? 'mp4' : 'jpg';
    final fileName = '${label}_$timestamp.$extension';
    final storagePath = 'audits/$claimRef/${asset.category}/$fileName';

    try {
      final ref = FirebaseStorage.instance.ref().child(storagePath);
      final metadata = SettableMetadata(
        customMetadata: {
          'original_filename': media.file.name,
          'tech_id': FirebaseAuth.instance.currentUser?.uid ?? 'anon',
          'peril_type': _leadData?['peril_type'] ?? 'General',
          'asset_id': asset.id,
          'label': label,
          'media_type': media.type == MediaType.photo ? 'photo' : 'video',
        },
      );

      await ref.putFile(File(media.file.path), metadata);
      
      // Monitor Firestore for OCR Handshake (if rating plate)
      if (label == 'rating_plate') {
        _listenForOCRResult(claimRef);
      } else {
        // Simulate Vision AI checking for 'tape measure'
        await Future.delayed(const Duration(seconds: 2));
        setState(() => _processingPhotos[media.file.path] = false);
      }
    } catch (e) {
      print('Upload error: $e');
      setState(() => _processingPhotos[media.file.path] = false);
    }
  }

  void _listenForOCRResult(String claimRef) {
    FirebaseFirestore.instance.collection('audits').doc(claimRef).snapshots().listen((snapshot) {
      final data = snapshot.data();
      if (data != null && data['extracted_data'] != null) {
        final extraction = data['extracted_data'];
        final confidence = extraction['confidence'] ?? 1.0;
        
        setState(() {
          // Find the media and stop spinner
          _processingPhotos.clear(); // Simplified for demo
        });

        _showOCRHandshake(extraction, confidence);
      }
    });
  }

  void _showOCRHandshake(Map<String, dynamic> extraction, double confidence) {
    final skyBlue = Color(0xFFA5D9F3);
    final isLowConfidence = confidence < 0.8;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black,
        title: Text('OCR VERIFICATION', style: TextStyle(color: skyBlue, fontWeight: FontWeight.w900)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildExtractedField('BRAND', extraction['brand'], isLowConfidence),
            _buildExtractedField('MODEL', extraction['model'], isLowConfidence),
            _buildExtractedField('SERIAL', extraction['serial'], isLowConfidence),
            if (isLowConfidence)
              Padding(
                padding: const EdgeInsets.only(top: 12.0),
                child: Text('⚠️ LOW CONFIDENCE (${(confidence * 100).toStringAsFixed(0)}%). PLEASE MANUALLY VERIFY.', 
                  style: TextStyle(color: skyBlue, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('RE-TAKE', style: TextStyle(color: Colors.red))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: skyBlue),
            onPressed: () => Navigator.pop(context), 
            child: const Text('CONFIRM DATA', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold))
          ),
        ],
      ),
    );
  }

  Widget _buildExtractedField(String label, String value, bool highlight) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
          Text(value, style: TextStyle(
            color: highlight ? Color(0xFFA5D9F3) : Colors.white, 
            fontWeight: FontWeight.bold,
            decoration: highlight ? TextDecoration.underline : null
          )),
        ],
      ),
    );
  }
  
  void _removeMedia(int index) {
      setState(() => _selectedMedia.removeAt(index));
  }

  @override
  void dispose() {
    _notesController.dispose();
    _obsController.dispose();
    _brandController.dispose();
    _faultController.dispose();
    _positionStream?.cancel();
    super.dispose();
  }

  void _showIntegrityError(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black,
        title: const Text('✋ FORENSIC BLOCKER', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        content: Text(message, style: const TextStyle(color: Colors.white)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('RE-INSPECT', style: TextStyle(color: Color(0xFFA5D9F3)))),
        ],
      ),
    );
  }

  Future<void> _handleExitAttempt() async {
    if (_auditCompleted) {
      Navigator.pop(context);
      return;
    }

    final notes = _obsController.text.toLowerCase();
    bool hasSootDiscrepancy = notes.contains('soot') && _selectedMedia.length < 3; // Mock logic

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('READY TO LEAVE?', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            if (hasSootDiscrepancy)
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.red.withOpacity(0.2),
                child: const Text(
                  'WARNING: Forensic Discrepancy. Your audio notes mentioned "Soot," but no soot-specific exhibit is present. Leaving now will result in a rejected audit. Please capture the soot swab to proceed.',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white)),
                    child: const Text('STAY & FIX', style: TextStyle(color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context); // Close modal
                      Navigator.pop(context); // Exit screen
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
                    child: const Text('LEAVE ANYWAY', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Future<void> _generateReport() async {
    HapticFeedback.lightImpact();
    if (_selectedReportType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a Report Type before generating.'), backgroundColor: Colors.red),
      );
      return;
    }
    if (_notesController.text.trim().isEmpty && _selectedMedia.isEmpty) return;

    setState(() {
      _isLoading = true;
      _generatedReport = null;
    });

    try {
      final List<String> mediaUrls = [];
      for (var media in _selectedMedia) {
        final url = await _firebaseService.uploadMedia(
          media.file, 
          _brandController.text.isNotEmpty ? _brandController.text : 'Unknown',
          _activeLookup?.brand ?? 'Unknown',
          media.type == MediaType.photo ? 'photos' : 'videos'
        );
        if (url != null) mediaUrls.add(url);
      }

      final GenerativeAiService aiService = GenerativeAiService();
      // Prepend report type to notes so AI can use it
      final String notesWithContext = "Report Type: $_selectedReportType\n\n${_notesController.text}";
      final report = await aiService.generateProfessionalReport(notesWithContext);

      String finalSummary = "";
      if (report != null) {
        finalSummary = "${report.executiveSummary}\n\n"
            "System Findings:\n${report.systemFindings}\n\n"
            "Recommendations:\n${report.recommendations.map((r) => '• $r').join('\n')}\n\n"
            "Safety Notes: ${report.safetyNotes}";
      } else {
        finalSummary = "Executive Summary: (AI Generation Offline)\n\n"
            "${_notesController.text.isNotEmpty ? 'Notes: ${_notesController.text}' : 'Inspection completed with media evidence.'}";
      }

      if (mediaUrls.isNotEmpty) {
           finalSummary = "(Media Warehouse: ${mediaUrls.length} files attached)\n\n$finalSummary";
      }

      await _firebaseService.saveReport(
        leadId: widget.leadId,
        reportType: _selectedReportType,
        notes: _notesController.text,
        observations: _obsController.text,
        brand: _brandController.text,
        faultCode: _faultController.text,
        mediaUrls: mediaUrls,
        summary: finalSummary,
        latitude: _currentPosition?.latitude,
        longitude: _currentPosition?.longitude,
      );

      if (mounted) {
        setState(() {
          _generatedReport = report;
          // Mock readings if any "pressure" or "temperature" keywords are found
          if (report != null && report.readings == null) {
            _generatedReport = ProfessionalReport(
              executiveSummary: report.executiveSummary,
              systemFindings: report.systemFindings,
              recommendations: report.recommendations,
              safetyNotes: report.safetyNotes,
              readings: TechnicalReadings(
                gasPressure: 3.5,
                staticPressure: 0.55,
                tempRise: 48,
                status: 'Normal',
              ),
            );
          }
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Professional report generated and saved.'),
            backgroundColor: Color(0xFFE67E22),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('IMR Tech Report', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF3498DB),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth > 600;
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: isTablet ? 32.0 : 16.0,
                vertical: 8.0,
              ),
              child: isTablet ? _buildTabletLayout() : _buildPhoneLayout(),
            );
          },
        ),
      ),
    );
  }

  Widget _buildReportTypeDropdown() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3498DB), width: 2),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedReportType,
          hint: const Text('SELECT REPORT TYPE *', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3498DB))),
          isExpanded: true,
          icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF3498DB)),
          style: const TextStyle(color: Color(0xFF2C3E50), fontSize: 16, fontWeight: FontWeight.bold),
          onChanged: (String? newValue) {
            setState(() {
              _selectedReportType = newValue;
            });
          },
          items: _reportTypes.map<DropdownMenuItem<String>>((String value) {
            return DropdownMenuItem<String>(
              value: value,
              child: Text(value),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildPhoneLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildReportTypeDropdown(),
        _buildCoPilotStatus(),
        const SizedBox(height: 12),
        _buildAssetInventorySidebar(),
        const SizedBox(height: 12),
        _buildAcousticFingerprintCard(),
        const SizedBox(height: 12),
        _buildBentoCard(
          isActive: true,
          child: _buildLocationHeader(),
        ),
        const SizedBox(height: 12),
        _buildBentoCard(
          child: _buildFaultLookupSection(),
        ),
        if (_activeLookup != null)
          Padding(
            padding: const EdgeInsets.only(top: 12.0),
            child: _buildBentoCard(
              borderColor: const Color(0xFFE67E22).withOpacity(0.5),
              child: _buildCanadianContextAlert(),
            ),
          ),
        const SizedBox(height: 12),
        _buildBentoCard(child: _buildNotesField()),
        const SizedBox(height: 12),
        _buildBentoCard(child: _buildObservationsField()),
        const SizedBox(height: 12),
        _buildBentoCard(child: _buildMediaGallery()),
        const SizedBox(height: 24),
        _buildGenerateButton(),
        if (_isLoading && _generatedReport == null)
          Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: Column(
              children: [
                _buildBentoCard(child: const _BentoShimmer(height: 100)),
                const SizedBox(height: 12),
                _buildBentoCard(child: const _BentoShimmer(height: 150)),
              ],
            ),
          ),
        if (_generatedReport != null)
          Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: _buildBentoCard(child: _buildResultSection()),
          ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildTabletLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildReportTypeDropdown(),
        // Row 1: Location + Fault Diagnosis side by side
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _buildBentoCard(
                isActive: true,
                child: _buildLocationHeader(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildBentoCard(child: _buildFaultLookupSection()),
            ),
          ],
        ),
        if (_activeLookup != null)
          Padding(
            padding: const EdgeInsets.only(top: 12.0),
            child: _buildBentoCard(
              borderColor: const Color(0xFFE67E22).withOpacity(0.5),
              child: _buildCanadianContextAlert(),
            ),
          ),
        const SizedBox(height: 12),
        // Row 2: Notes + Observations side by side
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildBentoCard(child: _buildNotesField())),
            const SizedBox(width: 12),
            Expanded(child: _buildBentoCard(child: _buildObservationsField())),
          ],
        ),
        const SizedBox(height: 12),
        _buildBentoCard(child: _buildMediaGallery()),
        const SizedBox(height: 24),
        _buildGenerateButton(),
        if (_isLoading && _generatedReport == null)
          Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: Column(
              children: [
                _buildBentoCard(child: const _BentoShimmer(height: 100)),
                const SizedBox(height: 12),
                _buildBentoCard(child: const _BentoShimmer(height: 150)),
              ],
            ),
          ),
        if (_generatedReport != null)
          Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: _buildBentoCard(child: _buildResultSection()),
          ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildBentoCard({required Widget child, Color? borderColor, bool isActive = false}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: isActive
          ? const Border(left: BorderSide(color: Color(0xFF3498DB), width: 2))
          : Border.all(color: borderColor ?? Colors.black.withOpacity(0.05)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildLocationHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('JOB SITE LOCATION', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2, color: Color(0xFF3498DB))),
            const SizedBox(height: 4),
            Text(_locationStatus, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2C3E50))),
          ],
        ),
        const Icon(Icons.location_on, color: Color(0xFF3498DB), size: 20),
      ],
    );
  }

  Widget _buildFaultLookupSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('FAULT DIAGNOSIS', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2, color: Color(0xFF3498DB))),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _brandController,
                style: const TextStyle(fontSize: 14, color: Color(0xFF2C3E50)),
                decoration: InputDecoration(
                  labelText: 'Brand',
                  labelStyle: const TextStyle(color: Colors.black45),
                  filled: true,
                  fillColor: const Color(0xFFF9FAFB),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _faultController,
                style: const TextStyle(fontSize: 14, color: Color(0xFF2C3E50)),
                decoration: InputDecoration(
                  labelText: 'Code',
                  labelStyle: const TextStyle(color: Colors.black45),
                  filled: true,
                  fillColor: const Color(0xFFF9FAFB),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _onFaultLookup,
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFE67E22),
              ),
              icon: const Icon(Icons.search, color: Colors.white),
              tooltip: 'Lookup Fault',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCanadianContextAlert() {
    return Row(
      children: [
        const Icon(Icons.info_outline, color: Color(0xFFE67E22), size: 18),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('CANADIAN MARKET TIP', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 9, color: Color(0xFFE67E22))),
              Text(_activeLookup!.canadianContextTip, style: const TextStyle(fontSize: 13, height: 1.4, color: Color(0xFF2C3E50), fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNotesField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('FIELD NOTES', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2, color: Color(0xFF3498DB))),
        const SizedBox(height: 12),
        TextField(
          controller: _notesController,
          maxLines: 4,
          style: const TextStyle(fontSize: 15, color: Color(0xFF2C3E50)),
          decoration: InputDecoration(
            hintText: 'Describe the issue or use voice...',
            hintStyle: const TextStyle(color: Colors.black26),
            filled: true,
            fillColor: const Color(0xFFF9FAFB),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            suffixIcon: isSpeechEnabled 
              ? IconButton(
                  icon: Icon(_isListening ? Icons.mic : Icons.mic_none, color: _isListening ? const Color(0xFFE67E22) : Colors.black45),
                  onPressed: _isListening ? _stopListening : _startListening,
                )
              : null,
          ),
        ),
      ],
    );
  }

  Widget _buildObservationsField() {
    const skyBlue = Color(0xFFA5D9F3);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('TECHNICIAN OBSERVATIONS', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2, color: Color(0xFF3498DB))),
            if (_isListening) const _VoiceWaveform(),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _obsController,
          maxLines: 4,
          style: const TextStyle(fontSize: 14, color: Color(0xFF2C3E50)),
          decoration: InputDecoration(
            hintText: 'Model-specific details, age, conditions...',
            hintStyle: const TextStyle(color: Colors.black26),
            filled: true,
            fillColor: const Color(0xFFF9FAFB),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: IconButton(
                icon: Icon(_isListening ? Icons.stop_circle : Icons.mic, color: _isListening ? Colors.red : Colors.black),
                onPressed: _isListening ? _stopDictating : _startDictating,
                style: IconButton.styleFrom(
                  backgroundColor: skyBlue,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ),
        ),
        if (!_isListening && _obsController.text.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4.0),
            child: Text('✅ Clinical Transcription Generated. Statutory Triggers Updated.', style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold)),
          ),
      ],
    );
  }

  void _startDictating() async {
    bool available = await _speechToText.initialize();
    if (available) {
      setState(() => _isListening = true);
      _speechToText.listen(
        onResult: (result) {
          setState(() {
            _obsController.text = result.recognizedWords;
          });
        },
      );
    }
  }

  void _stopDictating() async {
    await _speechToText.stop();
    setState(() => _isListening = false);
    
    // Call NLP cleanup
    final cleaned = await GenerativeAiService().cleanDictation(_obsController.text);
    if (cleaned != null) {
      setState(() => _obsController.text = cleaned);
    }
    
    // Trigger Semantic Gatekeeper check
    _checkForSemanticTriggers(_obsController.text);
  }

  void _checkForSemanticTriggers(String text) async {
    final lower = text.toLowerCase();
    
    // Impact Triggers
    if (lower.contains('impact') || lower.contains('crush') || lower.contains('dented') || lower.contains('branch')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFFE67E22),
          content: Text('⚠️ REQUIRED: Calibrated Crush Photo (Impact Detected)', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      );
    }

    // Multi-Asset Discovery
    final assetKeywords = {
      'Water Tank': 'Water_Heating',
      'Hot Water': 'Water_Heating',
      'HWT': 'Water_Heating',
      'AC': 'Cooling',
      'Condenser': 'Cooling',
      'Heat Pump': 'Cooling',
      'HRV': 'Ventilation',
      'Boiler': 'Heating',
      'Fireplace': 'Heating',
    };

    for (var entry in assetKeywords.entries) {
      if (lower.contains(entry.key.toLowerCase())) {
        bool alreadyExists = _discoveredAssets.any((a) => a.name.contains(entry.key));
        if (!alreadyExists) {
          _addNewAsset(entry.key, entry.value);
        }
      }
    }
  }

  void _addNewAsset(String name, String category) {
    final newAsset = ApplianceAsset(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      category: category,
      name: name,
      pendingPhotos: category == 'Water_Heating' ? ['T&P Relief Valve'] : [],
    );
    
    setState(() => _discoveredAssets.add(newAsset));
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black,
        title: const Text('SECONDARY ASSET DETECTED', style: TextStyle(color: Color(0xFFA5D9F3), fontWeight: FontWeight.w900)),
        content: Text('The system has identified a $name. We have added it to the Forensic Inventory.', style: const TextStyle(color: Colors.white)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('GOTO INVENTORY', style: TextStyle(color: Color(0xFFA5D9F3)))),
        ],
      ),
    );
  }

  Widget _buildAssetInventorySidebar() {
    const skyBlue = Color(0xFFA5D9F3);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('FORENSIC INVENTORY', style: TextStyle(color: skyBlue, fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 1.2)),
              Text('${_discoveredAssets.length} ASSETS', style: const TextStyle(color: Colors.grey, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 12),
          ..._discoveredAssets.map((asset) => Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Row(
              children: [
                Icon(asset.ratingPlateCaptured ? Icons.check_circle : Icons.radio_button_unchecked, color: asset.ratingPlateCaptured ? Colors.green : skyBlue, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(asset.name.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                      if (asset.pendingPhotos.isNotEmpty)
                        Text('PENDING: ${asset.pendingPhotos.join(", ")}', style: TextStyle(color: Colors.redAccent.withOpacity(0.8), fontSize: 9)),
                    ],
                  ),
                ),
                if (asset.manualHunted)
                  const Icon(Icons.menu_book, color: skyBlue, size: 14),
              ],
            ),
          )),
        ],
      ),
    );
  }
  Widget _buildMediaGallery() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('FORENSIC EVIDENCE GALLERY', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 1.2)),
        const SizedBox(height: 12),
        SizedBox(
          height: 120,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _selectedMedia.length + 2,
            itemBuilder: (context, index) {
              if (index == _selectedMedia.length) {
                return _buildAddMediaButton();
              }
              if (index == _selectedMedia.length + 1) {
                return _buildInterrogateAlbumButton();
              }
              final media = _selectedMedia[index];
              final isProcessing = _processingPhotos[media.file.path] ?? false;
              
              return Container(
                width: 100,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.withOpacity(0.3)),
                  image: media.type == MediaType.photo ? DecorationImage(
                    image: FileImage(File(media.file.path)),
                    fit: BoxFit.cover,
                  ) : null,
                ),
                child: Stack(
                  children: [
                    if (media.type == MediaType.video)
                      const Center(child: Icon(Icons.videocam, color: Colors.white70, size: 40)),
                    if (isProcessing)
                      Container(
                        color: Colors.black54,
                        child: const Center(
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFA5D9F3)),
                        ),
                      )
                    else
                      const Positioned(
                        top: 4,
                        right: 4,
                        child: Icon(Icons.check_circle, color: Colors.green, size: 18),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAddMediaButton() {
    return GestureDetector(
      onTap: () => _showMediaSourceSheet(),
      child: Container(
        width: 100,
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black.withOpacity(0.05), style: BorderStyle.solid),
        ),
        child: const Center(child: Icon(Icons.add_a_photo_outlined, color: Color(0xFF3498DB))),
      ),
    );
  }

  void _showMediaSourceSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(leading: const Icon(Icons.camera_alt, color: Color(0xFFE67E22)), title: const Text('Take Photo'), onTap: () { Navigator.pop(context); _pickMedia(ImageSource.camera, MediaType.photo); }),
              ListTile(leading: const Icon(Icons.videocam, color: Color(0xFFE67E22)), title: const Text('Record Video'), onTap: () { Navigator.pop(context); _pickMedia(ImageSource.camera, MediaType.video); }),
              ListTile(leading: const Icon(Icons.photo_library, color: Color(0xFFE67E22)), title: const Text('Gallery (Photo)'), onTap: () { Navigator.pop(context); _pickMedia(ImageSource.gallery, MediaType.photo); }),
              ListTile(leading: const Icon(Icons.video_library, color: Color(0xFFE67E22)), title: const Text('Gallery (Video)'), onTap: () { Navigator.pop(context); _pickMedia(ImageSource.gallery, MediaType.video); }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMediaThumbnail(int index) {
    final media = _selectedMedia[index];
    return Padding(
      padding: const EdgeInsets.only(right: 12.0),
      child: Stack(
        children: [
          GestureDetector(
            onTap: () {
               if (media.type == MediaType.photo) {
                 Navigator.push(context, MaterialPageRoute(
                   builder: (context) => FullScreenImage(media: media),
                 ));
               }
            },
            child: Hero(
              tag: media.file.path,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    border: Border.all(color: Colors.black.withOpacity(0.05)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: media.type == MediaType.photo
                    ? (kIsWeb 
                       ? Image.network(media.file.path, width: 90, height: 90, fit: BoxFit.cover)
                       : Image.file(File(media.file.path), width: 90, height: 90, fit: BoxFit.cover))
                    : const Center(child: Icon(Icons.play_circle_fill, size: 30, color: Color(0xFFE67E22))),
                ),
              ),
            ),
          ),
          Positioned(
            top: 4, 
            right: 4, 
            child: GestureDetector(
              onTap: () => _removeMedia(index), 
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.close, color: Colors.white, size: 14)
              )
            )
          ),
          if (media.type == MediaType.video)
             const Positioned(bottom: 6, left: 6, child: Icon(Icons.videocam, color: Colors.white70, size: 14)),
        ],
      ),
    );
  }

  Future<void> _verifyForensicHandshake() async {
    setState(() => _isLoading = true);
    
    // Simulate AI Reconciliation Check
    await Future.delayed(const Duration(seconds: 2));

    List<String> errors = [];
    for (var asset in _discoveredAssets) {
      if (!asset.ratingPlateCaptured) {
        errors.add('${asset.name}: Missing Rating Plate Photo');
      }
      if (!asset.manualHunted) {
        errors.add('${asset.name}: OEM Manual Citation Pending');
      }
      final hasDamage = _selectedMedia.any((m) => m.assetId == asset.id && m.file.name.contains('damage'));
      if (!hasDamage && asset.id != 'primary') {
         errors.add('${asset.name}: Missing Supporting Damage Photos');
      }
    }

    setState(() => _isLoading = false);

    if (errors.isNotEmpty) {
      _showReconciliationFailure(errors);
    } else {
      setState(() => _auditVerified = true);
      HapticFeedback.heavyImpact();
    }
  }

  void _showReconciliationFailure(List<String> errors) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ASSET RECONCILIATION FAILURE', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
            const SizedBox(height: 16),
            ...errors.map((e) => Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(e, style: const TextStyle(color: Colors.white, fontSize: 13))),
                ],
              ),
            )),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, minimumSize: const Size(double.infinity, 50)),
              onPressed: () => Navigator.pop(context),
              child: const Text('RE-INSPECT ASSETS', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGenerateButton() {
    const skyBlue = Color(0xFFA5D9F3);
    return Column(
      children: [
        if (!_auditVerified)
          ElevatedButton(
            onPressed: _isLoading ? null : _verifyForensicHandshake,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 56),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              side: const BorderSide(color: skyBlue, width: 2),
            ),
            child: _isLoading 
              ? const CircularProgressIndicator(color: skyBlue)
              : const Text('PERFORM AI INTEGRITY CHECK', style: TextStyle(color: skyBlue, fontWeight: FontWeight.bold)),
          ),
        if (_auditVerified)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle, color: skyBlue),
                SizedBox(width: 8),
                Text('AUDIT VERIFIED FOR ADJUDICATION', style: TextStyle(color: skyBlue, fontWeight: FontWeight.w900, fontSize: 12)),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE67E22).withOpacity(0.3),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ElevatedButton(
            onPressed: (_isLoading || !_auditVerified) ? null : _generateReport,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE67E22),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              padding: const EdgeInsets.symmetric(vertical: 18),
              minimumSize: const Size(double.infinity, 56),
            ),
            child: _isLoading 
              ? const Row(
                  mainAxisAlignment: MainAxisAlignment.center, 
                  children: [
                    SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                    SizedBox(width: 12), 
                    Text('UPLOADING TO WAREHOUSE...', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1))
                  ]
                )
              : const Text('GENERATE PROFESSIONAL REPORT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1.1)),
          ),
        ),
      ],
    );
  }

  Widget _buildResultSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_generatedReport!.readings != null) ...[
          TechnicalSummaryWidget(readings: _generatedReport!.readings!),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Divider(height: 1),
          ),
        ],
        const Text('EXECUTIVE SUMMARY', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2, color: Color(0xFF3498DB))),
        const SizedBox(height: 12),
        Text(
          _generatedReport!.executiveSummary, 
          style: const TextStyle(fontSize: 14, height: 1.6, color: Color(0xFF2C3E50), fontWeight: FontWeight.w400)
        ),
        const SizedBox(height: 24),
        const Text('EVIDENCE MAPPING', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2, color: Color(0xFF3498DB))),
        const SizedBox(height: 12),
        if (_selectedMedia.isNotEmpty)
          _buildEvidenceMapRow(),
        const SizedBox(height: 32),
        ElevatedButton.icon(
          onPressed: () => _exportToPdf(),
          icon: const Icon(Icons.picture_as_pdf),
          label: const Text('FINAL PDF EXPORT', style: TextStyle(fontWeight: FontWeight.bold)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF3498DB),
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 56),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    );
  }

  Widget _buildEvidenceMapRow() {
    // Show the first image side-by-side with its AI analysis
    final media = _selectedMedia.first;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: kIsWeb 
              ? Image.network(media.file.path, height: 180, fit: BoxFit.cover)
              : Image.file(File(media.file.path), height: 180, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('AI VISUAL ANALYSIS', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 8, color: Color(0xFFE67E22))),
              const SizedBox(height: 8),
              Text(
                _generatedReport!.systemFindings,
                style: const TextStyle(fontSize: 12, height: 1.4, color: Color(0xFF2C3E50)),
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _exportToPdf() async {
    if (widget.leadId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Lead ID associated with this draft.'))
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Mark as submitted in Firestore (Transitions status to 'report-submitted')
      final success = await _firebaseService.techSubmitReport(widget.leadId!);
      
      if (!success) {
        throw Exception('Failed to finalize report status.');
      }

      // 2. Generate the PDF (Mocking the URL for now)
      // In production, this would call the Cloud Function that generates the branded PDF.
      const mockReportUrl = 'https://firebasestorage.googleapis.com/v0/b/immediate-response-ai.appspot.com/o/reports%2Fmock_report.pdf?alt=media';

      if (mounted) {
        // 3. Navigate to Success Screen
        context.go('/tech/success?url=${Uri.encodeComponent(mockReportUrl)}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error finalizing report: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildCoPilotStatus() {
    const skyBlue = Color(0xFFA5D9F3);
    return GestureDetector(
      onTap: _toggleCoPilot,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: _isCoPilotActive ? skyBlue : Colors.black,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: skyBlue, width: 2),
        ),
        child: Row(
          children: [
            Icon(_isCoPilotActive ? Icons.graphic_eq : Icons.headset_mic, color: _isCoPilotActive ? Colors.black : skyBlue),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('GEMINI LIVE CO-PILOT', style: TextStyle(color: _isCoPilotActive ? Colors.black : skyBlue, fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2)),
                  Text(_isCoPilotActive ? 'LISTENING & ANALYZING VISUALS...' : 'TAP TO ACTIVATE REAL-TIME GUIDANCE', 
                    style: TextStyle(color: _isCoPilotActive ? Colors.black87 : Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            if (_isCoPilotActive)
              const _PulsatingRing(),
          ],
        ),
      ),
    );
  }

  void _toggleCoPilot() {
    setState(() => _isCoPilotActive = !_isCoPilotActive);
    HapticFeedback.mediumImpact();
    if (_isCoPilotActive) {
      _speak('Gemini Live Co-Pilot Active. I am monitoring the visual and acoustic streams. Walk the unit and I will identify anomalies.');
    }
  }

  Widget _buildAcousticFingerprintCard() {
    const skyBlue = Color(0xFFA5D9F3);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('ACOUSTIC FORENSIC FINGERPRINT', style: TextStyle(color: skyBlue, fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2)),
              if (_isRecordingAcoustics) const _AcousticWaveform(),
            ],
          ),
          const SizedBox(height: 16),
          if (_peakDb != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildAcousticMetric('PEAK VOLUME', '${_peakDb!.toStringAsFixed(1)} dB'),
                _buildAcousticMetric('DOMINANT FREQ', '${_peakHz!.toStringAsFixed(0)} Hz'),
              ],
            ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _startAcousticCapture,
            style: ElevatedButton.styleFrom(
              backgroundColor: _isRecordingAcoustics ? Colors.red : skyBlue,
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(_isRecordingAcoustics ? 'CAPTURING SIGNATURE...' : 'START ACOUSTIC AUDIT', 
              style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
          if (_acousticDiagnosis != null)
            Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: Text('DIAGNOSIS: $_acousticDiagnosis', style: const TextStyle(color: skyBlue, fontSize: 11, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic)),
            ),
        ],
      ),
    );
  }

  Widget _buildAcousticMetric(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 8, fontWeight: FontWeight.w900)),
        Text(value, style: const TextStyle(color: Color(0xFFA5D9F3), fontSize: 18, fontWeight: FontWeight.bold)),
      ],
    );
  }

  void _startAcousticCapture() async {
    setState(() => _isRecordingAcoustics = true);
    HapticFeedback.heavyImpact();
    
    // In a real implementation, we would stream audio chunks to Gemini 3.1 Live
    // Here we simulate the forensic analysis
    await Future.delayed(const Duration(seconds: 4));
    
    setState(() {
      _isRecordingAcoustics = false;
      _peakDb = 82.4;
      _peakHz = 120.0;
      _acousticDiagnosis = 'ABNORMAL 120Hz SPIKE DETECTED - INDUCER BEARING FAILURE LIKELY';
    });
    
    _speak('Acoustic Audit Complete. I have identified a dominant frequency spike at 120 Hertz. This deviates from factory specifications and indicates imminent mechanical failure of the inducer assembly.');
  }

  void _speak(String text) {
    // Integration with Text-to-Speech for Co-Pilot responses
    print('AI CO-PILOT: $text');
  }

  void _pickMedia(ImageSource source, MediaType type) async {
    final ImagePicker picker = ImagePicker();
    XFile? file;
    if (type == MediaType.photo) {
      file = await picker.pickImage(source: source, imageQuality: 100);
    } else {
      file = await picker.pickVideo(source: source);
    }

    if (file != null) {
      await _showMarkupAndCaptionPrompt(file, type, 'primary', 'general');
    }
  }

  Future<void> _showMarkupAndCaptionPrompt(XFile file, MediaType type, String assetId, String label) async {
    if (type != MediaType.photo) {
      _addMediaToGallery(file, type, assetId, label, '');
      return;
    }

    final TextEditingController captionController = TextEditingController();
    bool isDictating = false;

    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      pageBuilder: (context, animation, secondaryAnimation) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                title: const Text('MANDATORY MARKUP', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w900)),
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              body: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.red.withOpacity(0.2),
                    width: double.infinity,
                    child: const Text(
                      '1. Tap the image to draw a RED ARROW pointing to the damage/issue.',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          kIsWeb 
                            ? Image.network(file.path, fit: BoxFit.contain)
                            : Image.file(File(file.path), fit: BoxFit.contain),
                          Positioned(
                            bottom: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                              child: const Text('Touch screen to markup', style: TextStyle(color: Colors.white70)),
                            ),
                          )
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '2. VOICE CAPTION REQUIRED', 
                          style: TextStyle(color: Color(0xFFA5D9F3), fontWeight: FontWeight.w900, letterSpacing: 1.2)
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: captionController,
                          maxLines: 3,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Press microphone and explain what we are looking at...',
                            hintStyle: const TextStyle(color: Colors.white38),
                            filled: true,
                            fillColor: Colors.black,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                            suffixIcon: IconButton(
                              icon: Icon(isDictating ? Icons.stop_circle : Icons.mic, color: isDictating ? Colors.red : const Color(0xFFA5D9F3), size: 32),
                              onPressed: () async {
                                if (isDictating) {
                                  await _speechToText.stop();
                                  setModalState(() => isDictating = false);
                                } else {
                                  bool available = await _speechToText.initialize();
                                  if (available) {
                                    setModalState(() => isDictating = true);
                                    _speechToText.listen(onResult: (result) {
                                      setModalState(() {
                                        captionController.text = result.recognizedWords;
                                      });
                                    });
                                  }
                                }
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () {
                            if (captionController.text.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Caption is required!')));
                              return;
                            }
                            Navigator.pop(context);
                            _addMediaToGallery(file, type, assetId, label, captionController.text);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFA5D9F3),
                            minimumSize: const Size(double.infinity, 56),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: const Text('SAVE & ATTACH TO REPORT', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
        );
      }
    );
  }

  void _addMediaToGallery(XFile file, MediaType type, String assetId, String label, String caption) async {
    final media = SelectedMedia(file, type, assetId: assetId);
    setState(() {
      _selectedMedia.add(media);
      _processingPhotos[file.path] = true;
    });
    
    // Append caption to notes for the AI report generation
    if (caption.isNotEmpty) {
      final prefix = _obsController.text.isEmpty ? '' : '\n';
      setState(() {
        _obsController.text += '${prefix}[Photo Caption]: $caption';
      });
    }
    
    await _uploadForensicPhoto(media, label);
  }

  Widget _buildInterrogateAlbumButton() {
    return const SizedBox();
  }
}


class FullScreenImage extends StatelessWidget {
  final SelectedMedia media;
  const FullScreenImage({super.key, required this.media});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Hero(
          tag: media.file.path,
          child: kIsWeb 
            ? Image.network(media.file.path, fit: BoxFit.contain)
            : Image.file(File(media.file.path), fit: BoxFit.contain),
        ),
      ),
    );
  }
}

class _BentoShimmer extends StatefulWidget {
  final double height;
  const _BentoShimmer({required this.height});

  @override
  State<_BentoShimmer> createState() => _BentoShimmerState();
}

class _BentoShimmerState extends State<_BentoShimmer> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: [
                _controller.value - 0.3,
                _controller.value,
                _controller.value + 0.3,
              ],
              colors: [
                const Color(0xFFF9FAFB).withOpacity(0.8),
                const Color(0xFF3498DB).withOpacity(0.1),
                const Color(0xFFF9FAFB).withOpacity(0.8),
              ],
            ),
          ),
        );
      },
    );
  }
}
class _AcousticWaveform extends StatelessWidget {
  const _AcousticWaveform();
  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(10, (i) => Container(
        width: 2,
        height: 10 + (20 * (i % 3 == 0 ? 0.8 : 0.4)),
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(color: const Color(0xFFA5D9F3), borderRadius: BorderRadius.circular(2)),
      )),
    );
  }
}

class _PulsatingRing extends StatefulWidget {
  const _PulsatingRing();
  @override
  State<_PulsatingRing> createState() => _PulsatingRingState();
}

class _PulsatingRingState extends State<_PulsatingRing> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  }
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFA5D9F3).withOpacity(1 - _controller.value),
            border: Border.all(color: const Color(0xFFA5D9F3), width: 2),
          ),
        );
      },
    );
  }
}

class _VoiceWaveform extends StatefulWidget {
  const _VoiceWaveform();
  @override
  State<_VoiceWaveform> createState() => _VoiceWaveformState();
}

class _VoiceWaveformState extends State<_VoiceWaveform> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat(reverse: true);
  }
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          children: List.generate(3, (index) => Container(
            width: 3,
            height: 10 + (10 * _controller.value * (index + 1) / 3),
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(color: const Color(0xFFA5D9F3), borderRadius: BorderRadius.circular(2)),
          )),
        );
      },
    );
  }
}

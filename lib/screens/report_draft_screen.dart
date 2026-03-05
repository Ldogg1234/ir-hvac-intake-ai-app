import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../services/troubleshooting_service.dart';
import '../services/firebase_service.dart';
import '../services/generative_ai_service.dart';

class ReportDraftScreen extends StatefulWidget {
  const ReportDraftScreen({super.key});

  @override
  State<ReportDraftScreen> createState() => _ReportDraftScreenState();
}

enum MediaType { photo, video }

class SelectedMedia {
  final XFile file;
  final MediaType type;
  SelectedMedia(this.file, this.type);
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
  
  bool _isLoading = false;
  String? _executiveSummary;
  TroubleshootingResult? _activeLookup;
  
  bool isSpeechEnabled = false;
  bool _isListening = false;
  String _sttBaselineText = ''; // Snapshot of notes text at start of each listen session
  
  Position? _currentPosition;
  String _locationStatus = '';
  
  final List<SelectedMedia> _selectedMedia = [];

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _determinePosition();
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
  
  Future<void> _pickMedia(ImageSource source, MediaType type) async {
    HapticFeedback.lightImpact();
    try {
      XFile? result;
      if (type == MediaType.photo) {
        result = await _picker.pickImage(source: source);
      } else {
        result = await _picker.pickVideo(source: source);
      }

      if (result != null) {
        setState(() => _selectedMedia.add(SelectedMedia(result!, type)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('Error picking media: $e')),
        );
      }
    }
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
    super.dispose();
  }
  
  Future<void> _generateReport() async {
    HapticFeedback.lightImpact();
    if (_notesController.text.trim().isEmpty && _selectedMedia.isEmpty) return;

    setState(() {
      _isLoading = true;
      _executiveSummary = null;
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
      final report = await aiService.generateProfessionalReport(_notesController.text);

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
        setState(() => _executiveSummary = finalSummary);
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

  Widget _buildPhoneLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        _buildBentoCard(child: _buildPhotoSlots()),
        const SizedBox(height: 24),
        _buildGenerateButton(),
        if (_isLoading && _executiveSummary == null)
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
        if (_executiveSummary != null)
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
        _buildBentoCard(child: _buildPhotoSlots()),
        const SizedBox(height: 24),
        _buildGenerateButton(),
        if (_isLoading && _executiveSummary == null)
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
        if (_executiveSummary != null)
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('TECHNICIAN OBSERVATIONS', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2, color: Color(0xFF3498DB))),
        const SizedBox(height: 12),
        TextField(
          controller: _obsController,
          maxLines: 2,
          style: const TextStyle(fontSize: 14, color: Color(0xFF2C3E50)),
          decoration: InputDecoration(
            hintText: 'Model-specific details, age, conditions...',
            hintStyle: const TextStyle(color: Colors.black26),
            filled: true,
            fillColor: const Color(0xFFF9FAFB),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoSlots() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('EVIDENCE WAREHOUSE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2, color: Color(0xFF3498DB))),
        const SizedBox(height: 12),
        SizedBox(
          height: 90,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _selectedMedia.length + 1,
            itemBuilder: (context, index) {
              if (index == _selectedMedia.length) return _buildAddMediaButton();
              return _buildMediaThumbnail(index);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAddMediaButton() {
    return InkWell(
      onTap: () => _showMediaSourceSheet(),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 90,
        margin: const EdgeInsets.only(right: 12),
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

  Widget _buildGenerateButton() {
    return Container(
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
        onPressed: _isLoading ? null : _generateReport,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFE67E22),
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.symmetric(vertical: 18)
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
    );
  }

  Widget _buildResultSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('EXECUTIVE SUMMARY', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.2, color: Color(0xFF3498DB))),
        const SizedBox(height: 12),
        Text(
          _executiveSummary!, 
          style: const TextStyle(fontSize: 14, height: 1.6, color: Color(0xFF2C3E50), fontWeight: FontWeight.w400)
        ),
      ],
    );
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

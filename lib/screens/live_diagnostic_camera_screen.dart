import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:google_fonts/google_fonts.dart';

import '../ui/style/precision_theme.dart';
import '../widgets/diagnostic_chat_widget.dart';
import '../widgets/video_reference_dialog.dart';
import '../services/live_diagnostic_service.dart';

class LiveDiagnosticCameraScreen extends StatefulWidget {
  final String jobId;
  final String propertyAddress;
  final String jobType;

  const LiveDiagnosticCameraScreen({
    super.key,
    required this.jobId,
    required this.propertyAddress,
    required this.jobType,
  });

  @override
  State<LiveDiagnosticCameraScreen> createState() => _LiveDiagnosticCameraScreenState();
}

class _LiveDiagnosticCameraScreenState extends State<LiveDiagnosticCameraScreen> with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isAnalyzing = false;
  
  // Live Gemini 3.1 Session
  late final LiveDiagnosticService _liveDiagnosticService;
  List<String> _diagnosticLog = [];
  final Random _random = Random();
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _liveDiagnosticService = LiveDiagnosticService(jobId: widget.jobId);
    _initializeCamera();
    
    // Wire up callbacks
    _liveDiagnosticService.onAcousticAnomaly = (trigger) {
      if (!mounted) return;
      setState(() => _diagnosticLog.add("⚠ Acoustic Anomaly: ${trigger.dbFS.toStringAsFixed(1)}dB"));
    };
    _liveDiagnosticService.onGeminiDiagnosis = (diagnosis) {
      if (!mounted) return;
      setState(() {
        final prefix = diagnosis.anomalyDetected ? "⚠" : "💡";
        _diagnosticLog.add("$prefix ${diagnosis.type} (${(diagnosis.confidence * 100).toStringAsFixed(0)}% confidence)");
      });
    };
    _liveDiagnosticService.onFinalDiagnostic = (text) {
      if (!mounted) return;
      setState(() => _diagnosticLog.add("🗣 Tyler: $text"));
    };

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 0.1, end: 0.4).animate(_pulseController);
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint('No cameras found.');
        return;
      }
      
      final backCamera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: true,
      );

      await _cameraController!.initialize();
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

  void _toggleAnalysis() async {
    setState(() {
      _isAnalyzing = !_isAnalyzing;
    });

    if (_isAnalyzing) {
      // NOTE: You must provide a valid GEMINI_API_KEY for this string
      const String apiKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
      final bridgeUrl = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=\$apiKey';
      
      setState(() => _diagnosticLog.add("[Gemini Live] Connecting to 3.1 Flash..."));
      await _liveDiagnosticService.connectAndStartStreaming(bridgeUrl);
      setState(() => _diagnosticLog.add("[Gemini Live] Connected! Speak or show the camera."));
    } else {
      await _liveDiagnosticService.stopStreaming();
      setState(() {
        _diagnosticLog.add("[Gemini Live] Disconnected.");
      });
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _liveDiagnosticService.stopStreaming();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCameraInitialized || _cameraController == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: PrecisionTheme.primaryCyan, strokeWidth: 2),
              const SizedBox(height: 24),
              Text(
                'INITIALIZING OPTICS...',
                style: TextStyle(
                  color: PrecisionTheme.primaryCyan.withOpacity(0.8),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2.0,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF0A0A0A),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Camera Preview with subtle dark vignette
          CameraPreview(_cameraController!),
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.2,
                colors: [
                  Colors.transparent,
                  const Color(0xFF0A0A0A).withOpacity(0.8),
                ],
              ),
            ),
          ),

          // 2. HUD Scanning Overlay (when analyzing)
          if (_isAnalyzing)
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Stack(
                  children: [
                    // Top-to-bottom scan line
                    Positioned(
                      top: MediaQuery.of(context).size.height * _pulseAnimation.value * 2.5,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 2,
                        decoration: BoxDecoration(
                          boxShadow: const [
                            BoxShadow(
                              color: PrecisionTheme.primaryCyan,
                              blurRadius: 10,
                              spreadRadius: 2,
                            )
                          ],
                          color: PrecisionTheme.primaryCyan,
                        ),
                      ),
                    ),
                    // Edge glowing border
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: PrecisionTheme.primaryCyan.withOpacity(0.3 * (1.0 - _pulseAnimation.value)),
                          width: 2,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),

          // 3. Premium Glass Header
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 20,
            right: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.radar, color: PrecisionTheme.primaryCyan, size: 18),
                          const SizedBox(width: 12),
                          Text(
                            widget.propertyAddress.split(',').first.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        border: Border.all(color: Colors.white.withOpacity(0.1)),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 24),
                        onPressed: () {
                          _liveDiagnosticService.stopStreaming();
                          Navigator.of(context).pop();
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 4. Glassmorphism Diagnostic Console
          if (_diagnosticLog.isNotEmpty)
            Positioned(
              bottom: 140,
              left: 20,
              right: 20,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                  child: Container(
                    height: 160,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0A0A).withOpacity(0.4),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: PrecisionTheme.primaryCyan.withOpacity(0.2)),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _diagnosticLog.length,
                      physics: const BouncingScrollPhysics(),
                      itemBuilder: (context, index) {
                        final log = _diagnosticLog[index];
                        final isWarning = log.contains('⚠') || log.contains('shot');
                        final isInsight = log.contains('💡');
                        final isTyler = log.startsWith('🗣');
                        
                        // Parse video tokens e.g. [VIDEO:dQw4w9WgXcQ:45]
                        String displayText = log.replaceAll('🗣 Tyler: ', '');
                        String? videoId;
                        int? startSeconds;
                        
                        final videoMatch = RegExp(r'\[VIDEO:([a-zA-Z0-9_-]+):(\d+)\]').firstMatch(log);
                        if (videoMatch != null) {
                          videoId = videoMatch.group(1);
                          startSeconds = int.tryParse(videoMatch.group(2) ?? '0');
                          displayText = displayText.replaceAll(videoMatch.group(0)!, '').trim();
                        }

                        Color textColor = Colors.white70;
                        if (isWarning) textColor = const Color(0xFFFF5252);
                        if (isInsight) textColor = const Color(0xFFFFD740);
                        if (isTyler) textColor = PrecisionTheme.primaryCyan;
                        
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (isTyler) 
                                    const Padding(
                                      padding: EdgeInsets.only(right: 8.0, top: 2),
                                      child: Icon(Icons.graphic_eq, size: 14, color: PrecisionTheme.primaryCyan),
                                    ),
                                  Expanded(
                                    child: Text(
                                      displayText,
                                      style: TextStyle(
                                        color: textColor,
                                        fontFamily: isTyler ? 'Inter' : 'Courier',
                                        fontSize: isTyler ? 14 : 13,
                                        height: 1.4,
                                        fontWeight: isTyler ? FontWeight.w500 : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (videoId != null && startSeconds != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8.0, left: 22.0),
                                  child: GestureDetector(
                                    onTap: () {
                                      showDialog(
                                        context: context,
                                        builder: (context) => VideoReferenceDialog(
                                          videoId: videoId!,
                                          startSeconds: startSeconds!,
                                          title: 'Reference: Diagnosing the Issue',
                                        ),
                                      );
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: PrecisionTheme.primaryCyan.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(6), // Strict PrecisionTheme radius
                                        border: Border.all(color: PrecisionTheme.primaryCyan.withOpacity(0.5), width: 1),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.play_circle_fill, color: PrecisionTheme.primaryCyan, size: 16),
                                          const SizedBox(width: 8),
                                          Text(
                                            "PLAY REPAIR CLIP",
                                            style: GoogleFonts.spaceGrotesk(
                                              color: PrecisionTheme.primaryCyan,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 1.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),

          // 5. High-End Main Control Button
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _toggleAnalysis,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  height: 72,
                  width: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: _isAnalyzing 
                        ? [BoxShadow(color: Colors.redAccent.withOpacity(0.5), blurRadius: 20, spreadRadius: 5)]
                        : [BoxShadow(color: PrecisionTheme.primaryCyan.withOpacity(0.3), blurRadius: 15, spreadRadius: 2)],
                    gradient: LinearGradient(
                      colors: _isAnalyzing 
                          ? [Colors.redAccent, Colors.red.shade700]
                          : [PrecisionTheme.primaryCyan, Colors.blueAccent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      _isAnalyzing ? Icons.stop_rounded : Icons.camera_enhance_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ),
            ),
          ),
          
          // 6. Action status prompt
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                _isAnalyzing ? 'TRANSMITTING TELEMETRY...' : 'TAP TO INITIATE UPLINK',
                style: TextStyle(
                  color: _isAnalyzing ? Colors.redAccent : Colors.white54,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                  fontSize: 10,
                ),
              ),
            ),
          ),

          // 7. Glass Ask Tyler FAB
          Positioned(
            bottom: 40,
            right: 20,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF9B59B6).withOpacity(0.2),
                    border: Border.all(color: const Color(0xFF9B59B6).withOpacity(0.5)),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: FloatingActionButton(
                    heroTag: 'ask_tyler_fab_camera',
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (context) => Padding(
                          padding: EdgeInsets.only(
                            top: MediaQuery.of(context).padding.top + 40,
                          ),
                          child: const DiagnosticChatWidget(),
                        ),
                      );
                    },
                    child: const Icon(Icons.smart_toy_rounded, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

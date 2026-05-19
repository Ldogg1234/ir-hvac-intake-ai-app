import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/live_diagnostic_service.dart';

class LiveUXOverlay extends StatefulWidget {
  final LiveDiagnosticService diagnosticService;
  final String bridgeUrl;

  const LiveUXOverlay({
    Key? key,
    required this.diagnosticService,
    required this.bridgeUrl,
  }) : super(key: key);

  @override
  _LiveUXOverlayState createState() => _LiveUXOverlayState();
}

class _LiveUXOverlayState extends State<LiveUXOverlay> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _useSpeaker = true;
  bool _isRedFlag = false;
  Timer? _redFlagTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
       vsync: this,
       duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(_pulseController);

    // Set up diagnostic listeners for UI feedback
    widget.diagnosticService.onAcousticAnomaly = (trigger) {
      if (mounted) {
        // Red-flag frequency detected! Switch haptic glow to red.
        setState(() {
          _isRedFlag = true;
        });
        _redFlagTimer?.cancel();
        _redFlagTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _isRedFlag = false;
            });
          }
        });
      }
    };

    widget.diagnosticService.onGeminiDiagnosis = (diagnosis) {
      if (mounted && diagnosis.anomalyDetected && diagnosis.confidence > 0.75) {
        // High confidence from Gemini backend
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.warning_amber, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(child: Text("Acoustic Anomaly: ${diagnosis.type} (${(diagnosis.confidence * 100).toStringAsFixed(0)}% confidence)")),
              ],
            ),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    };

    widget.diagnosticService.onFinalDiagnostic = (text) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Diagnostic Summary'),
            content: SingleChildScrollView(child: Text(text)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Dismiss'))
            ],
          ),
        );
      }
    };

    widget.diagnosticService.onAcousticMatch = (matches) {
      if (mounted && matches.isNotEmpty) {
        final topMatch = matches.first;
        final label = topMatch['anomaly_label'] ?? 'Unknown Signature';
        // Assume high confidence if it returned a nearest neighbor early
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.saved_search, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(child: Text("Library Match: $label")),
              ],
            ),
            backgroundColor: Colors.blueAccent,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    };
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _redFlagTimer?.cancel();
    super.dispose();
  }

  void _toggleStreaming() async {
    if (widget.diagnosticService.isRecording) {
      await widget.diagnosticService.stopStreaming();
    } else {
      await widget.diagnosticService.connectAndStartStreaming(widget.bridgeUrl);
    }
    setState(() {});
  }

  void _toggleAudioRouting() async {
    setState(() {
      _useSpeaker = !_useSpeaker;
    });
    // Dynamically adjust output mid-stream
    await widget.diagnosticService.initializeAudioRouting(forceSpeaker: _useSpeaker);
  }

  @override
  Widget build(BuildContext context) {
    bool isLive = widget.diagnosticService.isRecording;

    return Positioned(
      bottom: 24.0,
      right: 24.0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Camera Preview Widget
          if (isLive && widget.diagnosticService.cameraController != null && widget.diagnosticService.cameraController!.value.isInitialized)
            Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12.0),
                child: Container(
                  width: 100,
                  height: 140,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.redAccent, width: 2.0),
                  ),
                  child: CameraPreview(widget.diagnosticService.cameraController!),
                ),
              ),
            ),
          
          // Audio Routing Toggle Button (Headset vs Speaker)
          if (isLive)
            FloatingActionButton.small(
              onPressed: _toggleAudioRouting,
              backgroundColor: Colors.grey[800],
              child: Icon(
                _useSpeaker ? Icons.volume_up : Icons.headset_mic,
                color: Colors.white,
              ),
              tooltip: _useSpeaker ? 'Speaker Active' : 'Headset Active',
            ),
          const SizedBox(height: 12),
          // Main AI Recording Status Button
          ScaleTransition(
            scale: isLive ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
            child: Container(
              decoration: isLive
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _isRedFlag ? Colors.redAccent : Colors.greenAccent,
                        width: 4.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _isRedFlag ? Colors.redAccent.withOpacity(0.6) : Colors.greenAccent.withOpacity(0.6),
                          blurRadius: 15,
                          spreadRadius: 2,
                        )
                      ],
                    )
                  : null,
              child: FloatingActionButton(
                onPressed: _toggleStreaming,
                backgroundColor: Colors.grey[850], // Dark inner button
                child: Icon(
                  isLive ? Icons.mic : Icons.mic_none,
                  color: isLive ? (_isRedFlag ? Colors.redAccent : Colors.greenAccent) : Colors.white,
                ),
                tooltip: isLive ? 'Stop AI Stream' : 'Start Diagnostic AI',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

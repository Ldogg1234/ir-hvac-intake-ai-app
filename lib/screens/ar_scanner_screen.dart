import 'package:flutter/material.dart';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'package:camera/camera.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';

class ARScannerScreen extends StatefulWidget {
  final String leadId;
  final String scanId;

  const ARScannerScreen({
    Key? key,
    required this.leadId,
    required this.scanId,
  }) : super(key: key);

  @override
  _ARScannerScreenState createState() => _ARScannerScreenState();
}

class _ARScannerScreenState extends State<ARScannerScreen> {
  late ARKitController arkitController;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final FlutterTts _flutterTts = FlutterTts();
  
  bool _isRecording = false;
  String _latestFeedback = "Awaiting feedback...";
  
  // Basic Spatial Tracking State
  double? _ceilingHeight;
  List<double> _wallClearances = [];

  @override
  void initState() {
    super.initState();
    _initTts();
    // In production, prompt for camera/microphone permissions here.
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
  }

  @override
  void dispose() {
    arkitController.dispose();
    _audioPlayer.dispose();
    _audioRecorder.dispose();
    _flutterTts.stop();
    super.dispose();
  }

  /// Initialize ARKit and start detecting planes (LiDAR enabled via config if available)
  void onARKitViewCreated(ARKitController arkitController) {
    this.arkitController = arkitController;
    this.arkitController.onAddNodeForAnchor = _handleAddAnchor;
  }

  /// Handle detected planes (Walls/Floors)
  void _handleAddAnchor(ARKitAnchor anchor) {
    if (anchor is ARKitPlaneAnchor) {
      // Calculate spatial logic based on anchor transformations.
      // E.g., determining height by evaluating Y-axis translation against gravity.
      // This is simplified for MVP purposes.
      setState(() {
        _ceilingHeight = anchor.transform.getTranslation().y.abs() * 2.0; // Rough heuristic
        _wallClearances.add(anchor.extent.x);
      });
    }
  }

  /// Capture a camera frame, record audio snippet, and send to Firebase MVP Endpoint
  Future<void> _sendFrameToGemini() async {
    if (_isRecording) return;
    setState(() => _isRecording = true);

    try {
      // 1. Capture Audio
      final String audioPath = '${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(const RecordConfig(), path: audioPath);
      
      // Simulate technician talking for a few seconds
      await Future.delayed(const Duration(seconds: 3));
      final String? finalAudioPath = await _audioRecorder.stop();
      
      // In production, convert the audio file to Base64
      final String audioBase64 = "MOCK_AUDIO_BASE64"; 
      final String imageBase64 = "MOCK_IMAGE_BASE64"; // Usually captured from arkitController or camera controller

      // 2. Prepare spatial metrics payload (Edge Processing)
      final spatialMetrics = {
        "ceilingHeight": _ceilingHeight,
        "wallClearances": _wallClearances,
      };

      // 3. Send to Cloud Function MVP
      final response = await http.post(
        Uri.parse('https://us-central1-immediate-response-ai-b18b8.cloudfunctions.net/geminiLiveStreamMvp'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "leadId": widget.leadId,
          "scanId": widget.scanId,
          "audioBase64": audioBase64,
          "imageBase64": imageBase64,
          "spatialMetrics": spatialMetrics,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String feedback = data['feedback'] ?? '';
        
        setState(() {
          _latestFeedback = feedback;
        });

        // Use Text-to-Speech (or play back returned audio buffer if the endpoint supports it)
        if (feedback.isNotEmpty) {
          await _flutterTts.speak(feedback);
        }
      }
    } catch (e) {
      debugPrint('Error sending frame to Gemini: \$e');
      setState(() {
        _latestFeedback = "Network Error.";
      });
    } finally {
      setState(() => _isRecording = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LiDAR Spatial Scanner'),
        backgroundColor: Colors.black87,
      ),
      body: Stack(
        children: [
          ARKitSceneView(
            onARKitViewCreated: onARKitViewCreated,
            planeDetection: ARPlaneDetection.horizontalAndVertical, // Detect floors and walls
          ),
          
          // HUD for Spatial Metrics
          Positioned(
            top: 20,
            left: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black54,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Ceiling Height: \${_ceilingHeight?.toStringAsFixed(2) ?? 'Detecting...'} m",
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  Text(
                    "Walls Detected: \${_wallClearances.length}",
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
            ),
          ),

          // HUD for Gemini Feedback
          Positioned(
            bottom: 100,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blueAccent.withOpacity(0.8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _latestFeedback,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _sendFrameToGemini,
        label: Text(_isRecording ? 'Recording...' : 'Hold & Speak'),
        icon: Icon(_isRecording ? Icons.mic : Icons.mic_none),
        backgroundColor: _isRecording ? Colors.red : Colors.blue,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

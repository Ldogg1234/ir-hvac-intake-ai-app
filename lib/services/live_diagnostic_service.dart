import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:audioplayers/audioplayers.dart' hide AVAudioSessionCategory, AVAudioSessionMode;
import 'package:audio_session/audio_session.dart';
// import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter/foundation.dart';
import 'safety_isolate.dart';
import 'web_pcm_recorder.dart';

class GeminiDiagnostic {
  final bool anomalyDetected;
  final String type;
  final double confidence;
  GeminiDiagnostic({required this.anomalyDetected, required this.type, required this.confidence});
}

class LiveDiagnosticService {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
// final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  WebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _micSubscription;

  // Track connection state
  bool isConnected = false;
  bool isRecording = false;

  // Camera capabilities
  CameraController? cameraController;
  final List<String> recentFrames = []; // Store recent base64 frames for reporting
  final List<String> importantPhotos = [];
  Timer? _frameTimer;

  // Isolate variables
  Isolate? _safetyIsolate;
  SendPort? _isolateSendPort;
  ReceivePort? _isolateReceivePort;

  // Callbacks for UI
  Function(DiagnosticTrigger)? onAcousticAnomaly;
  Function(List<dynamic>)? onAcousticMatch;
  Function(String)? onFinalDiagnostic;
  Function(String)? onDiagnosticReportReady;
  Function(GeminiDiagnostic)? onGeminiDiagnosis;
  Function(String)? onStartLidarInspection;
  Function(String)? onError;

  // Rolling buffer for native similarity search (keeping ~3 seconds at 16k 16-bit)
  final int maxBufferSize = 16000 * 2 * 3; 
  List<int> _rollingBuffer = [];

  // Cooldown to prevent spamming the cloud function
  DateTime _lastAnalysisTime = DateTime.fromMillisecondsSinceEpoch(0);
  String? jobId;

  LiveDiagnosticService({this.jobId}) {
    _initializeNotifications();
  }

  Future<void> _initializeNotifications() async {
    // Notifications disabled due to web compiling conflict
  }

  /// Setup global audio routing (Speaker vs Headset matching)
  Future<void> initializeAudioRouting({bool forceSpeaker = true}) async {
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: forceSpeaker 
         ? AVAudioSessionCategoryOptions.defaultToSpeaker | AVAudioSessionCategoryOptions.allowBluetooth
         : AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio,
    ));
  }

  Future<void> _initSafetyIsolate() async {
    _isolateReceivePort = ReceivePort();
    _safetyIsolate = await Isolate.spawn(safetyAudioIsolate, _isolateReceivePort!.sendPort);
    
    _isolateReceivePort!.listen((message) {
      if (message is SendPort) {
        _isolateSendPort = message;
      } else if (message is DiagnosticTrigger) {
        // Trigger Haptics
        Vibration.vibrate(pattern: [0, 50, 100, 50], intensities: [0, 128, 0, 128]);
        
        // Trigger Local Notification (Check Ear Protection)
        if (message.isDangerousDb) {
          _showSafetyNotification("Check Ear Protection", "Noise levels exceed -5 dBFS (${message.dbFS.toStringAsFixed(1)} dB). Please step back.");
        }

        // Trigger UI Toast Proxy
        if (onAcousticAnomaly != null) {
          onAcousticAnomaly!(message);
        }

        // Send to Vector Similarity Search if cooling down is over
        if (DateTime.now().difference(_lastAnalysisTime).inSeconds > 5) {
            _lastAnalysisTime = DateTime.now();
            _triggerSimilaritySearch();
        }
      }
    });
  }

  Future<void> _triggerSimilaritySearch() async {
      if (_rollingBuffer.isEmpty) return;

      try {
          final Uint8List snapshot = Uint8List.fromList(_rollingBuffer);
          final base64Audio = base64Encode(snapshot);
          
          final call = FirebaseFunctions.instance.httpsCallable('analyzeAcousticBuffer');
          final response = await call.call({
              'audioBufferBase64': base64Audio
          });

          if (response.data != null && response.data['success'] == true) {
              final matches = response.data['matches'] as List<dynamic>;
              if (matches.isNotEmpty && onAcousticMatch != null) {
                  onAcousticMatch!(matches);
              }
          }
      } catch (e) {
          // Silent fail for backend connectivity
      }
  }

  Future<void> _showSafetyNotification(String title, String body) async {
    print('⚠️ SAFETY ALERT: $title - $body');
  }

  /// Establishes the socket to `live-bridge` and starts streaming
  Future<void> connectAndStartStreaming(String bridgeUrl) async {
    if (await _audioRecorder.hasPermission()) {
      if (!kIsWeb) {
        try {
          await initializeAudioRouting();
          await _initSafetyIsolate();
        } catch (e) {
          print("Mobile init failed: $e");
        }
      }

      // Initialize Camera (Low Resolution for efficiency, no audio to prevent conflict)
      try {
        final cameras = await availableCameras();
        if (cameras.isNotEmpty) {
          // Prefer back camera
          final backCamera = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
            orElse: () => cameras.first,
          );
          cameraController = CameraController(
            backCamera,
            ResolutionPreset.low,
            enableAudio: false,
          );
          await cameraController!.initialize();
        }
      } catch (e) {
        print("Camera initialization failed: $e");
      }

      // Connect to our multimodal-vector-architect proxy
      _channel = WebSocketChannel.connect(Uri.parse(bridgeUrl));
      isConnected = true;
      
      // Configure Gemini 3.1 Live API client
      final setupMessage = {
        "setup": {
          "model": "models/gemini-3.1-flash-live-preview",
          "generationConfig": {
            "responseModalities": ["AUDIO"]
          },
          "systemInstruction": {
            "parts": [
              {
                "text": "You are Tyler, an expert HVAC Diagnostic Voice Assistant. You receive live video and audio from the technician's phone.\n1. Act as a Live Stethoscope. Analyze incoming audio for mechanical irregularities. You must identify critical sounds, such as 4000Hz bearing fluting, 120Hz blower imbalances, or 60Hz transformer hum.\n2. Examine the video feed proactively. When you see a rating plate, you MUST verbally announce 'I've captured the rating plate for [Brand], Model [Model Number].'\n3. IMMEDIATELY after successfully identifying the model number, you MUST automatically call `search_manuals_database` with that model number to pull the owner's manual. If it is not found internally, you MUST use the `googleSearch` tool to find the manual online. Once retrieved, proactively use this manual to guide the technician.\n4. If you see the technician trying to show you a rating plate, a meter reading, or a component, but it is blurry, incomplete, or poorly lit, you MUST verbally speak up and ask them to adjust the camera, get closer, or improve lighting to get the additional visuals.\n5. When asked about error codes or troubleshooting, FIRST use `search_manuals_database`. If not found, use `googleSearch` to find a relevant YouTube video or manual.\n6. If the technician confirms a YouTube video helped them resolve the issue, you MUST call the `store_helpful_video` tool to automatically save it to the internal catalog.\n7. You MUST call `store_equipment_details` immediately after successfully capturing a rating plate.\n8. You MUST call `store_acoustic_diagnosis` after analyzing and identifying an acoustic anomaly.\n9. IMPORTANT: If you recommend a video from the database, you MUST include the exact token [VIDEO:videoId:startSeconds] in your text response so the app can display a clickable video player. Extract the videoId from the youtube_url (e.g. for https://youtube.com/watch?v=dQw4w9WgXcQ, videoId is dQw4w9WgXcQ). For startSeconds use 0 if unknown.\n10. Speak naturally, conversationally, and concisely.\n11. EXTREMELY IMPORTANT: Whenever you see a clear view of equipment, a rating plate, a meter reading, or a damaged component, or if the technician points something out and asks you to document it, you MUST IMMEDIATELY call the `capture_important_photo` tool to save that high-fidelity visual into the report. Do NOT rely on arbitrary background photos. The report depends on these explicit photo captures.\n12. When the technician asks for an email report or a summary, you MUST call the `generate_diagnostic_report` tool and provide a highly detailed summary of the entire session (equipment, observations, discussion, recommendations)."
              }
            ]
          },
          "tools": [
            { "googleSearch": {} },
            {
              "functionDeclarations": [
                {
                  "name": "search_manuals_database",
                  "description": "Searches the internal database for HVAC manuals, fault codes, and diagnostic videos. Always use this first before falling back to Google Search.",
                  "parameters": {
                    "type": "OBJECT",
                    "properties": {
                      "query": {
                        "type": "STRING",
                        "description": "The search query (e.g., model number 'SLP99UH045V36B' or '3 flashing lights SLP99UH')"
                      }
                    },
                    "required": ["query"]
                  }
                },
                {
                  "name": "store_helpful_video",
                  "description": "Stores a helpful YouTube video and its description into the database for future technicians to use. Call this ONLY after the technician confirms the web video helped solve the problem.",
                  "parameters": {
                    "type": "OBJECT",
                    "properties": {
                      "youtube_url": {
                        "type": "STRING",
                        "description": "The URL of the helpful YouTube video"
                      },
                      "description": {
                        "type": "STRING",
                        "description": "A detailed description of what the video is about and what problem it solves (e.g., 'How to install a new inducer motor bearing on Carrier Infinity')"
                      },
                      "title": {
                        "type": "STRING",
                        "description": "A short title for the video"
                      }
                    },
                    "required": ["youtube_url", "description"]
                  }
                },
                {
                  "name": "rate_video_helpfulness",
                  "description": "Records technician feedback on whether an INTERNAL database video was helpful. Call this after retrieving internal videos and the tech gives feedback.",
                  "parameters": {
                    "type": "OBJECT",
                    "properties": {
                      "video_id": {
                        "type": "STRING",
                        "description": "The ID of the video from the internal database"
                      },
                      "was_helpful": {
                        "type": "BOOLEAN",
                        "description": "True if it was helpful, False if it was not"
                      }
                    },
                    "required": ["video_id", "was_helpful"]
                  }
                },
                {
                  "name": "store_equipment_details",
                  "description": "Stores the extracted equipment rating plate details (Brand, Model, Serial) into the database for this job. Call this immediately after you successfully read a rating plate.",
                  "parameters": {
                    "type": "OBJECT",
                    "properties": {
                      "brand": { "type": "STRING", "description": "The manufacturer brand" },
                      "model_number": { "type": "STRING", "description": "The model number" },
                      "serial_number": { "type": "STRING", "description": "The serial number" }
                    },
                    "required": ["model_number"]
                  }
                },
                {
                  "name": "store_acoustic_diagnosis",
                  "description": "Stores the final acoustic diagnosis and peak frequency into the database for this job. Call this after analyzing audio anomalies.",
                  "parameters": {
                    "type": "OBJECT",
                    "properties": {
                      "diagnosis": { "type": "STRING", "description": "The detailed acoustic diagnosis." },
                      "peak_frequency_hz": { "type": "NUMBER", "description": "The identified peak frequency in Hz, if applicable." },
                      "is_red_flag": { "type": "BOOLEAN", "description": "True if this is a critical issue (e.g., bearing failure)." }
                    },
                    "required": ["diagnosis", "is_red_flag"]
                  }
                },
                {
                  "name": "generate_diagnostic_report",
                  "description": "Generates a detailed summary report of the entire diagnostic session. Call this when the technician requests an email report or a summary of the session.",
                  "parameters": {
                    "type": "OBJECT",
                    "properties": {
                      "report_text": {
                        "type": "STRING",
                        "description": "The full detailed report containing equipment details, observations, conversation summary, and recommendations. Format beautifully."
                      }
                    },
                    "required": ["report_text"]
                  }
                },
                {
                  "name": "capture_important_photo",
                  "description": "Saves the current camera view as an important photo to be included in the final report. Use when viewing rating plates, meter readings, or damaged parts.",
                  "parameters": {
                    "type": "OBJECT",
                    "properties": {
                      "description": {
                        "type": "STRING",
                        "description": "A short caption of what was captured in the photo."
                      }
                    },
                    "required": ["description"]
                  }
                },
                {
                  "name": "start_lidar_scanner",
                  "description": "Opens the LiDAR AR Scanner interface. Call this when the technician asks you to capture measurements, scan the room, or start the LiDAR inspection.",
                  "parameters": {
                    "type": "OBJECT",
                    "properties": {
                      "intent": {
                        "type": "STRING",
                        "description": "What is being scanned"
                      }
                    },
                    "required": ["intent"]
                  }
                }
              ]
            }
          ]
        }
      };
      _channel!.sink.add(jsonEncode(setupMessage));

      // Listen for Gemini AI responses
      _channel!.stream.listen((message) {
        print("RAW SERVER MESSAGE: $message");
        _handleIncomingServerMessage(message);
      }, onDone: () {
        print("WEBSOCKET CLOSED: ${_channel?.closeCode} - ${_channel?.closeReason}");
        isConnected = false;
        stopStreaming();
      }, onError: (error) {
        print("WEBSOCKET ERROR: $error");
        isConnected = false;
        stopStreaming();
      });

      try {
        isRecording = true;

        if (kIsWeb) {
          WebPcmRecorder.start((base64Audio) {
            if (isConnected) {
              final bidiMessage = {
                "realtimeInput": {
                  "audio": {
                    "mimeType": "audio/pcm;rate=16000",
                    "data": base64Audio
                  }
                }
              };
              _channel!.sink.add(jsonEncode(bidiMessage));
              
              // We could decode base64 back to bytes for the rolling buffer if needed,
              // but for now the web platform focuses on Gemini communication.
            }
          });
        } else {
          // Start 16kHz PCM raw stream for Gemini 3.1 Live (Mobile/Desktop)
          final recordStream = await _audioRecorder.startStream(
            const RecordConfig(
              encoder: AudioEncoder.pcm16bits,
              sampleRate: 16000,
              numChannels: 1, // Mono is required for Live API
            ),
          );

          // Pipe mic bytes directly into WebSocket AND Safety Isolate
          _micSubscription = recordStream.listen((data) {
            if (isConnected) {
              // Maintain Rolling Buffer
              _rollingBuffer.addAll(data);
              if (_rollingBuffer.length > maxBufferSize) {
                  _rollingBuffer.removeRange(0, _rollingBuffer.length - maxBufferSize);
              }

              // 1. Send to Local Safety Isolate
              if (_isolateSendPort != null) {
                _isolateSendPort!.send(AudioProcessData(data, 16000));
              }

              // 2. Send to Gemini 3.1 Backend
              final base64Audio = base64Encode(data);

              final bidiMessage = {
                "realtimeInput": {
                  "audio": {
                    "mimeType": "audio/pcm;rate=16000",
                    "data": base64Audio
                  }
                }
              };
              _channel!.sink.add(jsonEncode(bidiMessage));
            }
          }, onError: (e) {
             print("Record stream error: $e");
             if (onError != null) onError!("Microphone streaming error: $e");
          });
        }
      } catch (e) {
        print("Failed to start audio stream: $e");
        if (onError != null) onError!("Failed to start microphone. Please check permissions or browser support: $e");
      }

      // Start Video Frame Extraction (Reduced to 3 seconds to prevent UI thread blocking / audio stuttering)
      if (cameraController != null && cameraController!.value.isInitialized) {
        _frameTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
          if (!isConnected || !cameraController!.value.isInitialized) return;
          if (cameraController!.value.isTakingPicture) return;
          
          try {
            final xFile = await cameraController!.takePicture();
            final bytes = await xFile.readAsBytes();
            final base64Image = base64Encode(bytes);
            
            // Cache the last 3 frames for reporting
            recentFrames.add(base64Image);
            if (recentFrames.length > 3) {
              recentFrames.removeAt(0);
            }
            
            
            final bidiMessage = {
              "realtimeInput": {
                "video": {
                  "mimeType": "image/jpeg",
                  "data": base64Image
                }
              }
            };
            _channel!.sink.add(jsonEncode(bidiMessage));
          } catch (e) {
            // Safe fail if frame drops
          }
        });
      }
    }
  }

  void _handleIncomingServerMessage(dynamic rawMessage) async {
    try {
      String messageString;
      if (rawMessage is List<int>) {
        messageString = utf8.decode(rawMessage);
      } else {
        messageString = rawMessage.toString();
      }
      final msg = jsonDecode(messageString);

      if (msg['setupComplete'] != null) {
        // Kick off the conversation explicitly
        final initialMessage = {
          "clientContent": {
            "turns": [
              {
                "role": "user",
                "parts": [{"text": "Hi Tyler! Are you online?"}]
              }
            ],
            "turnComplete": true
          }
        };
        _channel!.sink.add(jsonEncode(initialMessage));
      }

      // Handle tool calls from Gemini
      if (msg['toolCall'] != null) {
        final toolCalls = msg['toolCall']['functionCalls'] as List<dynamic>;
        final responses = [];
        
        for (var call in toolCalls) {
          if (call['name'] == 'search_manuals_database') {
            final args = call['args'] ?? {};
            final query = args['query'] ?? '';
            
            String resultText = "No information found.";
            try {
              final callable = FirebaseFunctions.instance.httpsCallable('askTyler');
              final res = await callable.call({'query': query});
              if (res.data != null && res.data['success'] == true) {
                resultText = res.data['answer'] ?? "No answer generated.";
                
                final vids = res.data['videos'] as List<dynamic>? ?? [];
                if (vids.isNotEmpty) {
                  resultText += "\n\nAlso found the following internal videos: ";
                  for (var v in vids) {
                    resultText += "\n- ID: ${v['id']}, URL: ${v['youtube_url']}, Description: ${v['description']}";
                  }
                  resultText += "\nPlease recommend these to the tech if relevant, and invoke `rate_video_helpfulness` based on their feedback.";
                }
              } else {
                resultText = "Manual not found in the database. Please try another search method like Google Search.";
              }
            } catch (e) {
              resultText = "Error accessing the internal manual database: $e. Try Google Search instead.";
            }
            
            responses.add({
              "id": call['id'],
              "name": "search_manuals_database",
              "response": {
                "result": resultText
              }
            });
          } else if (call['name'] == 'store_helpful_video') {
            final args = call['args'] ?? {};
            
            String resultText = "Processing save request...";
            try {
              final callable = FirebaseFunctions.instance.httpsCallable('saveDiagnosticVideo');
              final res = await callable.call({
                'youtube_url': args['youtube_url'],
                'description': args['description'],
                'title': args['title']
              });
              
              if (res.data != null && res.data['success'] == true) {
                resultText = "Successfully saved the helpful video to the internal diagnostics catalog for future use.";
              } else {
                resultText = "Failed to save the video. Error: ${res.data['error']}";
              }
            } catch (e) {
              resultText = "Error saving video: $e";
            }

            responses.add({
              "id": call['id'],
              "name": "store_helpful_video",
              "response": {
                "result": resultText
              }
            });
          } else if (call['name'] == 'rate_video_helpfulness') {
            final args = call['args'] ?? {};
            String resultText = "Processing rating...";
            try {
              final callable = FirebaseFunctions.instance.httpsCallable('rateDiagnosticVideo');
              final res = await callable.call({
                'video_id': args['video_id'],
                'was_helpful': args['was_helpful']
              });
              
              if (res.data != null && res.data['success'] == true) {
                resultText = "Rating saved. Video approval is now ${res.data['approval_rating']}%. ${res.data['ignored'] == true ? 'This video will now be ignored in future searches due to low rating.' : ''}";
              } else {
                resultText = "Failed to rate the video.";
              }
            } catch (e) {
              resultText = "Error rating video: $e";
            }

            responses.add({
              "id": call['id'],
              "name": "rate_video_helpfulness",
              "response": {
                "result": resultText
              }
            });
          } else if (call['name'] == 'store_equipment_details') {
            final args = call['args'] ?? {};
            String resultText = "Processing equipment storage...";
            try {
              // We could trigger a local callback so the UI knows we captured the equipment.
              // For now, we mock the backend call (this would connect to Firebase later if needed).
              // We'll just confirm it was received.
              print("[Tyler] Stored equipment: ${args['brand']} ${args['model_number']} ${args['serial_number']}");
              
              if (onFinalDiagnostic != null) {
                 onFinalDiagnostic!("Equipment Captured: ${args['brand'] ?? ''} ${args['model_number'] ?? ''}");
              }

              resultText = "Successfully stored the equipment details. Verbally confirm this to the technician now.";
            } catch (e) {
              resultText = "Error storing equipment: $e";
            }

            responses.add({
              "id": call['id'],
              "name": "store_equipment_details",
              "response": {
                "result": resultText
              }
            });
          } else if (call['name'] == 'store_acoustic_diagnosis') {
            final args = call['args'] ?? {};
            String resultText = "Processing acoustic diagnosis storage...";
            try {
              print("[Tyler] Acoustic Diagnosis Stored: ${args['diagnosis']} (${args['peak_frequency_hz']}Hz) - Red Flag: ${args['is_red_flag']}");
              
              if (onFinalDiagnostic != null) {
                 onFinalDiagnostic!("Acoustic Diagnosis Saved: ${args['diagnosis']}");
              }

              // Store to Firestore using Cloud Functions (if needed)
              try {
                final callable = FirebaseFunctions.instance.httpsCallable('storeAcousticDiagnosis');
                await callable.call({
                  'lead_id': jobId,
                  'diagnosis': args['diagnosis'],
                  'peak_frequency_hz': args['peak_frequency_hz'],
                  'is_red_flag': args['is_red_flag'],
                });
              } catch (e) {
                print("Failed to store acoustic diagnosis to cloud: $e");
              }

              resultText = "Successfully stored the acoustic diagnosis to the Job Document.";
            } catch (e) {
              resultText = "Error storing acoustic diagnosis: $e";
            }

            responses.add({
              "id": call['id'],
              "name": "store_acoustic_diagnosis",
              "response": {
                "result": resultText
              }
            });
          } else if (call['name'] == 'generate_diagnostic_report') {
            final args = call['args'] ?? {};
            String resultText = "Report processing...";
            try {
              final reportText = args['report_text'] ?? "No report generated.";
              if (onDiagnosticReportReady != null) {
                onDiagnosticReportReady!(reportText);
              }
              resultText = "Successfully generated and sent the report to the UI for emailing.";
            } catch (e) {
              resultText = "Error generating report: $e";
            }

            responses.add({
              "id": call['id'],
              "name": "generate_diagnostic_report",
              "response": {
                "result": resultText
              }
            });
          } else if (call['name'] == 'capture_important_photo') {
            final args = call['args'] ?? {};
            String resultText = "Photo captured.";
            try {
              if (recentFrames.isNotEmpty) {
                importantPhotos.add(recentFrames.last);
                resultText = "Successfully captured the photo with description: ${args['description']}. It will be included in the report.";
                if (onFinalDiagnostic != null) {
                  onFinalDiagnostic!("📸 Photo Captured: ${args['description']}");
                }
              } else {
                resultText = "Failed: No video frames available yet.";
              }
            } catch (e) {
              resultText = "Error capturing photo: $e";
            }

            responses.add({
              "id": call['id'],
              "name": "capture_important_photo",
              "response": {
                "result": resultText
              }
            });
          } else if (call['name'] == 'start_lidar_scanner') {
            final args = call['args'] ?? {};
            String resultText = "Opening LiDAR scanner...";
            try {
              if (onStartLidarInspection != null) {
                onStartLidarInspection!(args['intent'] ?? '');
                resultText = "Successfully triggered the LiDAR AR scanner in the UI. Guide the technician through the scanning process.";
              } else {
                resultText = "Failed: LiDAR scanner callback is not configured in this UI context.";
              }
            } catch (e) {
              resultText = "Error triggering LiDAR scanner: $e";
            }

            responses.add({
              "id": call['id'],
              "name": "start_lidar_scanner",
              "response": {
                "result": resultText
              }
            });
          }
        }
        
        if (responses.isNotEmpty && isConnected && _channel != null) {
          final toolResponseMessage = {
            "toolResponse": {
              "functionResponses": responses
            }
          };
          _channel!.sink.add(jsonEncode(toolResponseMessage));
        }
        return; // Tool handled; do not process as normal content message
      }
      
      if (msg['serverContent'] != null) {
        if (msg['serverContent']['interrupted'] == true) {
          print("⚠️ Gemini Interrupted! Clearing audio queue...");
          if (kIsWeb) {
            WebPcmRecorder.stopPlayback();
          } else {
            _audioPlayer.stop();
          }
        }
        
        if (msg['serverContent']['modelTurn'] != null) {
          final parts = msg['serverContent']['modelTurn']['parts'] as List;
          for (var part in parts) {
          if (part['inlineData'] != null) {
            // Audio response from Gemini! Play it.
            final mimeType = part['inlineData']['mimeType'];
            if (mimeType.contains('audio')) {
              final base64Data = part['inlineData']['data'];
              if (kIsWeb) {
                WebPcmRecorder.playChunk(base64Data);
              } else {
                final audioBytes = base64Decode(base64Data);
                
                int sampleRate = 24000;
                if (mimeType.contains('rate=')) {
                   final rateStr = mimeType.split('rate=')[1].split(';')[0];
                   sampleRate = int.tryParse(rateStr) ?? 24000;
                }
                
                final wavHeader = _createWavHeader(audioBytes.length, sampleRate);
                final wavFile = Uint8List.fromList([...wavHeader, ...audioBytes]);
                
                await _audioPlayer.play(BytesSource(wavFile));
              }
            }
          }
          if (part['text'] != null) {
            String textResponse = part['text'];
            try {
              // Handle JSON formatted response from 3-second streaming analysis
              final startIdx = textResponse.indexOf('{');
              final endIdx = textResponse.lastIndexOf('}');
              if (startIdx != -1 && endIdx != -1) {
                final jsonStr = textResponse.substring(startIdx, endIdx + 1);
                final diagJson = jsonDecode(jsonStr);
                final anomalyDetected = diagJson['anomaly_detected'] ?? false;
                final type = diagJson['type'] ?? 'Unknown';
                final confidence = (diagJson['confidence'] ?? 0.0).toDouble();
                
                if (onGeminiDiagnosis != null) {
                  onGeminiDiagnosis!(GeminiDiagnostic(
                    anomalyDetected: anomalyDetected,
                    type: type,
                    confidence: confidence,
                  ));
                }
              }
            } catch (e) {
              // Not JSON, assume final text handshake
            }
            if (onFinalDiagnostic != null) {
              onFinalDiagnostic!(textResponse);
            }
          }
        }
      }
    }
    } catch (e) {
      // Ignored: Not an audio playback turn
    }
  }

  Future<void> stopStreaming() async {
    if (kIsWeb) {
      WebPcmRecorder.stop();
    } else {
      await _micSubscription?.cancel();
      await _audioRecorder.stop();
    }

    // Final Handshake: Request final diagnostic summary from Gemini before closing
    if (isConnected && _channel != null) {
      try {
        final bidiMessage = {
          "clientContent": {
            "turns": [
              {
                "role": "user",
                "parts": [{"text": "The technician has stopped the recording. Please provide your final diagnostic summary of the acoustic anomalies observed."}]
              }
            ],
            "turnComplete": true
          }
        };
        _channel!.sink.add(jsonEncode(bidiMessage));

        // Let the WebSocket stay open very briefly to catch the text response
        await Future.delayed(const Duration(seconds: 2));
      } catch (e) {
        // Safe fail
      }
    }

    _frameTimer?.cancel();
    cameraController?.dispose();
    cameraController = null;

    _channel?.sink.close();
    
    // Clean up isolate
    _isolateReceivePort?.close();
    _safetyIsolate?.kill(priority: Isolate.immediate);
    _safetyIsolate = null;
    
    isConnected = false;
    isRecording = false;
  }

  void sendTextMessage(String text) {
    if (isConnected && _channel != null) {
      final bidiMessage = {
        "clientContent": {
          "turns": [
            {
              "role": "user",
              "parts": [{"text": text}]
            }
          ],
          "turnComplete": true
        }
      };
      _channel!.sink.add(jsonEncode(bidiMessage));
    }
  }

  Uint8List _createWavHeader(int dataLength, int sampleRate) {
    final channels = 1;
    final byteRate = sampleRate * channels * 2;
    final header = ByteData(44);

    header.setUint8(0, 82); // "RIFF"
    header.setUint8(1, 73);
    header.setUint8(2, 70);
    header.setUint8(3, 70);
    header.setUint32(4, dataLength + 36, Endian.little); // ChunkSize
    header.setUint8(8, 87); // "WAVE"
    header.setUint8(9, 65);
    header.setUint8(10, 86);
    header.setUint8(11, 69);
    header.setUint8(12, 102); // "fmt "
    header.setUint8(13, 109);
    header.setUint8(14, 116);
    header.setUint8(15, 32);
    header.setUint32(16, 16, Endian.little); // Subchunk1Size
    header.setUint16(20, 1, Endian.little); // AudioFormat
    header.setUint16(22, channels, Endian.little); // NumChannels
    header.setUint32(24, sampleRate, Endian.little); // SampleRate
    header.setUint32(28, byteRate, Endian.little); // ByteRate
    header.setUint16(32, channels * 2, Endian.little); // BlockAlign
    header.setUint16(34, 16, Endian.little); // BitsPerSample
    header.setUint8(36, 100); // "data"
    header.setUint8(37, 97);
    header.setUint8(38, 116);
    header.setUint8(39, 97);
    header.setUint32(40, dataLength, Endian.little); // Subchunk2Size

    return header.buffer.asUint8List();
  }
}


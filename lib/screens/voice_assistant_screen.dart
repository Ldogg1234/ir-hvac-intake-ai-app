import 'package:flutter/material.dart';
import 'dart:math';
import 'package:cloud_functions/cloud_functions.dart';
import '../services/live_diagnostic_service.dart';
import '../main.dart' as import_main;
import 'ar_scanner_export.dart';

class VoiceAssistantScreen extends StatefulWidget {
  final String? leadId;

  const VoiceAssistantScreen({super.key, this.leadId});

  @override
  State<VoiceAssistantScreen> createState() => _VoiceAssistantScreenState();
}

class _VoiceAssistantScreenState extends State<VoiceAssistantScreen> with SingleTickerProviderStateMixin {
  late final LiveDiagnosticService _liveDiagnosticService;
  final TextEditingController _textController = TextEditingController();
  
  bool _isLiveActive = false;
  
  final List<Map<String, String>> _messages = [];
  final ScrollController _scrollController = ScrollController();
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    import_main.showGlobalFab.value = false;
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    
    _liveDiagnosticService = LiveDiagnosticService(jobId: widget.leadId);
    
    _liveDiagnosticService.onFinalDiagnostic = (text) {
      if (!mounted) return;
      setState(() {
        _messages.add({'role': 'assistant', 'text': text});
      });
      _scrollToBottom();
    };
    
    _liveDiagnosticService.onStartLidarInspection = (intent) {
      if (!mounted) return;
      
      final scanId = 'scan_${DateTime.now().millisecondsSinceEpoch}';
      import_main.showGlobalFab.value = false;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ARScannerScreen(
            leadId: widget.leadId ?? 'test_session',
            scanId: scanId,
          ),
        ),
      );
    };
    
    _liveDiagnosticService.onGeminiDiagnosis = (diagnosis) {
      if (!mounted) return;
      final prefix = diagnosis.anomalyDetected ? "⚠" : "💡";
      setState(() {
        _messages.add({
          'role': 'assistant',
          'text': "$prefix ${diagnosis.type} (${(diagnosis.confidence * 100).toStringAsFixed(0)}% confidence)"
        });
      });
      _scrollToBottom();
    };

    _liveDiagnosticService.onError = (errorMsg) {
      if (!mounted) return;
      setState(() {
        _messages.add({'role': 'system', 'text': 'ERROR: $errorMsg'});
      });
      _scrollToBottom();
    };

    _liveDiagnosticService.onDiagnosticReportReady = (reportText) async {
      if (!mounted) return;
      
      // We got the detailed report from Gemini! Now send the email.
      try {
        String html = '<div><h2>Diagnostic Report</h2><p>${reportText.replaceAll('\n', '<br>')}</p>';
        html += '</div><hr/><h3>Raw Log</h3><div>';
        for (final msg in _messages) {
          if (msg['role'] == 'system') continue;
          final color = msg['role'] == 'user' ? '#0066cc' : '#333333';
          final name = msg['role'] == 'user' ? 'Technician' : 'Tyler';
          html += '<p><strong><span style="color:$color">$name:</span></strong> ${msg['text']}</p>';
        }
        html += '</div>';

        final callable = FirebaseFunctions.instance.httpsCallable('emailTylerTranscript');
        await callable.call({
          'htmlTranscript': html,
          'importantPhotos': _liveDiagnosticService.importantPhotos,
          'recentFrames': _liveDiagnosticService.recentFrames,
          'leadId': widget.leadId,
        });

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Detailed diagnostic report emailed successfully!')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send email: $e')),
        );
      } finally {
        if (mounted) {
          setState(() {
            _isEmailing = false;
          });
        }
      }
    };

    _messages.add({
      'role': 'assistant',
      'text': 'Hi! I am Tyler, your HVAC Co-Pilot powered by Gemini 3.1 Live. Tap the microphone to start our live session.'
    });
  }

  @override
  void dispose() {
    import_main.showGlobalFab.value = true;
    _textController.dispose();
    _pulseController.dispose();
    _liveDiagnosticService.stopStreaming();
    super.dispose();
  }

  void _toggleLiveSession() async {
    if (_isLiveActive) {
      await _liveDiagnosticService.stopStreaming();
      setState(() {
        _isLiveActive = false;
        _messages.add({'role': 'system', 'text': 'Live session disconnected.'});
      });
      _scrollToBottom();
    } else {
      setState(() {
        _isLiveActive = true;
        _messages.add({'role': 'system', 'text': 'Connecting to Gemini 3.1 Live...'});
      });
      _scrollToBottom();
      
      String apiKey = const String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
      if (apiKey.isEmpty) {
        // Fallback to test key if not provided via environment
        apiKey = 'AIzaSyAaGzFJa9x7j8btqmprXe4kbi2CWyYgo3A';
      }
      
      final bridgeUrl = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=$apiKey';
      
      await _liveDiagnosticService.connectAndStartStreaming(bridgeUrl);
      
      setState(() {
        _messages.add({'role': 'system', 'text': 'Live session connected. I am listening...'});
      });
      _scrollToBottom();
    }
  }

  void _processTextQuery(String text) {
    if (text.trim().isEmpty) return;
    
    setState(() {
      _messages.add({'role': 'user', 'text': text});
    });
    _scrollToBottom();

    if (_isLiveActive) {
      _liveDiagnosticService.sendTextMessage(text);
    } else {
      setState(() {
        _messages.add({'role': 'assistant', 'text': 'Please tap the microphone to connect the Live session first.'});
      });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _isEmailing = false;

  void _sendTranscriptEmail() async {
    if (_messages.isEmpty) return;

    setState(() {
      _isEmailing = true;
    });

    if (_isLiveActive) {
      // Request a detailed report from Tyler via the open connection
      _messages.add({'role': 'system', 'text': 'Requesting detailed email report from Tyler...'});
      _scrollToBottom();
      _liveDiagnosticService.sendTextMessage("The technician has requested an email report. Please call the `generate_diagnostic_report` tool with a highly detailed summary of our entire session, including equipment details, what you observed, what we discussed, and your recommendations. Output nicely formatted text.");
    } else {
      // Fallback: If disconnected, we can't ask Tyler to summarize anymore.
      try {
        String html = '<div><p><em>Note: Live session was disconnected before report generation. This is only the raw UI log.</em></p>';
        for (final msg in _messages) {
          if (msg['role'] == 'system') continue;
          final color = msg['role'] == 'user' ? '#0066cc' : '#333333';
          final name = msg['role'] == 'user' ? 'Technician' : 'Tyler';
          html += '<p><strong><span style="color:$color">$name:</span></strong> ${msg['text']}</p>';
        }
        html += '</div>';

        final callable = FirebaseFunctions.instance.httpsCallable('emailTylerTranscript');
        await callable.call({
          'htmlTranscript': html,
          'importantPhotos': _liveDiagnosticService.importantPhotos,
          'recentFrames': _liveDiagnosticService.recentFrames,
          'leadId': widget.leadId ?? 'test_session',
        });

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Raw transcript emailed successfully!')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send email: $e')),
        );
      } finally {
        if (mounted) {
          setState(() {
            _isEmailing = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0F1C),
      appBar: AppBar(
        title: const Text('HVAC Voice Assistant', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1A233A),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          if (_isEmailing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
            )
          else
            IconButton(
              icon: const Icon(Icons.email_outlined),
              tooltip: 'Email Transcript to Me',
              onPressed: _sendTranscriptEmail,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isUser = msg['role'] == 'user';
                final isSystem = msg['role'] == 'system';
                
                if (isSystem) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        msg['text']!,
                        style: const TextStyle(color: Colors.white54, fontSize: 12, fontStyle: FontStyle.italic),
                      ),
                    ),
                  );
                }

                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                    decoration: BoxDecoration(
                      color: isUser ? const Color(0xFF3498DB) : const Color(0xFF1A233A),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: isUser ? const Radius.circular(16) : const Radius.circular(0),
                        bottomRight: isUser ? const Radius.circular(0) : const Radius.circular(16),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        )
                      ],
                    ),
                    child: Text(
                      msg['text']!,
                      style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                    ),
                  ),
                );
              },
            ),
          ),
            
          // Input Area
          Container(
            padding: const EdgeInsets.only(top: 16, bottom: 40, left: 16, right: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF0A0F1C).withOpacity(0.0),
                  const Color(0xFF0A0F1C),
                ],
              ),
            ),
            child: Column(
              children: [
                // LiDAR button
                Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        final scanId = 'scan_${DateTime.now().millisecondsSinceEpoch}';
                        import_main.showGlobalFab.value = false;
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => ARScannerScreen(
                              leadId: widget.leadId ?? 'test_session',
                              scanId: scanId,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.view_in_ar, color: Colors.white, size: 20),
                        label: const Text('START LiDAR INSPECTION', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF9B59B6),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: "Type a message...",
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                      filled: true,
                      fillColor: const Color(0xFF1A233A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    ),
                    onSubmitted: (value) {
                      if (value.isNotEmpty) {
                        _processTextQuery(value);
                        _textController.clear();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                // Send button
                GestureDetector(
                  onTap: () {
                    if (_textController.text.isNotEmpty) {
                      _processTextQuery(_textController.text);
                      _textController.clear();
                    }
                  },
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF3498DB),
                    ),
                    child: const Icon(Icons.send, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 8),
                // Mic / Live Toggle Button
                GestureDetector(
                  onTap: _toggleLiveSession,
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      final scale = _isLiveActive ? 1.0 + (_pulseController.value * 0.15) : 1.0;
                      final glowOpacity = _isLiveActive ? 0.3 + (_pulseController.value * 0.3) : 0.0;
                      
                      return Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isLiveActive ? Colors.redAccent : const Color(0xFF00E5FF),
                          boxShadow: [
                            if (_isLiveActive)
                              BoxShadow(
                                color: Colors.redAccent.withOpacity(glowOpacity),
                                blurRadius: 15,
                                spreadRadius: 5,
                              )
                          ],
                        ),
                        child: Transform.scale(
                          scale: scale,
                          child: Icon(
                            _isLiveActive ? Icons.stop_rounded : Icons.mic,
                            color: _isLiveActive ? Colors.white : Colors.black,
                            size: 24,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
      ),
    );
  }
}


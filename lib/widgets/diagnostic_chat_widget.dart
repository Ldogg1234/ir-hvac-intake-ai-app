import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/live_diagnostic_service.dart';

class ChatMessage {
  final String text;
  final bool isUser;
  final bool isSystem;

  ChatMessage({required this.text, required this.isUser, this.isSystem = false});
}

class DiagnosticChatWidget extends StatefulWidget {
  const DiagnosticChatWidget({super.key});

  @override
  State<DiagnosticChatWidget> createState() => _DiagnosticChatWidgetState();
}

class _DiagnosticChatWidgetState extends State<DiagnosticChatWidget> with SingleTickerProviderStateMixin {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  late final LiveDiagnosticService _liveDiagnosticService;
  bool _isLiveActive = false;
  late AnimationController _pulseController;

  final List<ChatMessage> _messages = [
    ChatMessage(
      text: "Hi! I'm Tyler, your AI Tech Assistant powered by Gemini 3.1 Live. Tap the microphone to connect the Live session!",
      isUser: false,
    ),
  ];

  @override
  void initState() {
    super.initState();
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    
    _liveDiagnosticService = LiveDiagnosticService();
    
    _liveDiagnosticService.onFinalDiagnostic = (text) {
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(text: text, isUser: false));
      });
      _scrollToBottom();
    };
    
    _liveDiagnosticService.onGeminiDiagnosis = (diagnosis) {
      if (!mounted) return;
      final prefix = diagnosis.anomalyDetected ? "⚠" : "💡";
      setState(() {
        _messages.add(ChatMessage(
          text: "$prefix ${diagnosis.type} (${(diagnosis.confidence * 100).toStringAsFixed(0)}% confidence)",
          isUser: false,
        ));
      });
      _scrollToBottom();
    };
  }
  
  @override
  void dispose() {
    _scrollController.dispose();
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
        _messages.add(ChatMessage(text: 'Live session disconnected.', isUser: false, isSystem: true));
      });
      _scrollToBottom();
    } else {
      setState(() {
        _isLiveActive = true;
        _messages.add(ChatMessage(text: 'Connecting to Gemini 3.1 Live...', isUser: false, isSystem: true));
      });
      _scrollToBottom();
      
      const String apiKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
      if (apiKey.isEmpty) {
        setState(() {
          _isLiveActive = false;
          _messages.add(ChatMessage(text: 'Error: GEMINI_API_KEY is not set. Please build with --dart-define=GEMINI_API_KEY=YOUR_KEY', isUser: false, isSystem: true));
        });
        _scrollToBottom();
        return;
      }
      
      final bridgeUrl = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=$apiKey';
      
      await _liveDiagnosticService.connectAndStartStreaming(bridgeUrl);
      
      setState(() {
        _messages.add(ChatMessage(text: 'Live session connected. I am listening...', isUser: false, isSystem: true));
      });
      _scrollToBottom();
    }
  }

  void _handleSubmitted(String text) {
    if (text.trim().isEmpty) return;
    
    _textController.clear();
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true));
    });
    _scrollToBottom();

    if (_isLiveActive) {
      _liveDiagnosticService.sendTextMessage(text);
    } else {
      setState(() {
        _messages.add(ChatMessage(text: 'Please tap the microphone to connect the Live session first.', isUser: false));
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

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(30),
          topRight: Radius.circular(30),
        ),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            decoration: const BoxDecoration(
              color: Color(0xFF1E3A5F),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(30),
                topRight: Radius.circular(30),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.smart_toy, color: Colors.blueAccent, size: 28),
                    SizedBox(width: 12),
                    Text(
                      'Tyler the AI Tech',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          
          // Chat Messages List
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _buildMessageBubble(msg);
              },
            ),
          ),

          // Input Area
          Container(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: Row(
              children: [
                // Text Field
                Expanded(
                  child: TextField(
                    controller: _textController,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _handleSubmitted,
                    decoration: InputDecoration(
                      hintText: "Type a message...",
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      filled: true,
                      fillColor: Colors.grey[100],
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                
                // Send Button
                GestureDetector(
                  onTap: () => _handleSubmitted(_textController.text),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: const BoxDecoration(
                      color: Color(0xFF3498DB),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.send, color: Colors.white, size: 22),
                  ),
                ),
                const SizedBox(width: 12),
                
                // Mic / Live Toggle Button
                GestureDetector(
                  onTap: _toggleLiveSession,
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      final scale = _isLiveActive ? 1.0 + (_pulseController.value * 0.15) : 1.0;
                      final glowOpacity = _isLiveActive ? 0.3 + (_pulseController.value * 0.3) : 0.0;
                      
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isLiveActive ? Colors.redAccent : Colors.blue.withOpacity(0.1),
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
                            _isLiveActive ? Icons.stop_rounded : Icons.mic_none,
                            color: _isLiveActive ? Colors.white : Colors.blue,
                            size: 26,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    if (msg.isSystem) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            msg.text,
            style: TextStyle(color: Colors.grey[500], fontSize: 12, fontStyle: FontStyle.italic),
          ),
        ),
      );
    }
    
    // Parse video tokens e.g. [VIDEO:dQw4w9WgXcQ:45]
    String displayText = msg.text;
    String? videoId;
    int? startSeconds;
    
    if (!msg.isUser) {
      final videoMatch = RegExp(r'\[VIDEO:([a-zA-Z0-9_-]+):(\d+)\]').firstMatch(displayText);
      if (videoMatch != null) {
        videoId = videoMatch.group(1);
        startSeconds = int.tryParse(videoMatch.group(2) ?? '0');
        displayText = displayText.replaceAll(videoMatch.group(0)!, '').trim();
      }
    }
  
    return Align(
      alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: msg.isUser ? const Color(0xFF3498DB) : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(msg.isUser ? 20 : 0),
            bottomRight: Radius.circular(msg.isUser ? 0 : 20),
          ),
          boxShadow: [
            if (!msg.isUser)
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              displayText,
              style: TextStyle(
                color: msg.isUser ? Colors.white : const Color(0xFF2C3E50),
                fontSize: 15,
                height: 1.4,
              ),
            ),
            if (videoId != null && startSeconds != null) ...[
              const SizedBox(height: 16),
              _buildVideoCard(videoId, startSeconds),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildVideoCard(String videoId, int startSeconds) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            _launchUrl("https://youtube.com/watch?v=$videoId&t=${startSeconds}s");
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow, color: Colors.redAccent, size: 28),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "REFERENCE VIDEO",
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.blueAccent,
                          letterSpacing: 1.2,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        "Tap to play recommended solution clip",
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF2C3E50),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'package:google_fonts/google_fonts.dart';
import '../ui/style/precision_theme.dart';

class VideoReferenceDialog extends StatefulWidget {
  final String videoId;
  final int startSeconds;
  final int? endSeconds;
  final String title;

  const VideoReferenceDialog({
    super.key,
    required this.videoId,
    required this.startSeconds,
    this.endSeconds,
    required this.title,
  });

  @override
  State<VideoReferenceDialog> createState() => _VideoReferenceDialogState();
}

class _VideoReferenceDialogState extends State<VideoReferenceDialog> {
  late YoutubePlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.videoId,
      autoPlay: true,
      startSeconds: widget.startSeconds.toDouble(),
      endSeconds: widget.endSeconds?.toDouble(),
      params: const YoutubePlayerParams(
        showControls: true,
        showFullscreenButton: true,
        mute: false,
      ),
    );
  }

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          color: PrecisionTheme.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: PrecisionTheme.ghostBorder, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: PrecisionTheme.ghostBorder, width: 1),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.smart_display_rounded, color: PrecisionTheme.primaryCyan, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.title.toUpperCase(),
                      style: GoogleFonts.spaceGrotesk(
                        color: PrecisionTheme.pureWhite,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            
            // YouTube Player
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                child: YoutubePlayer(
                  controller: _controller,
                ),
              ),
            ),
            
            // Footer
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                color: PrecisionTheme.surfaceVeryDark,
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, color: Colors.white54, size: 14),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Extracted from AI Knowledge Base. Start: ${widget.startSeconds}s",
                      style: GoogleFonts.inter(color: Colors.white54, fontSize: 11),
                    ),
                  ),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }
}

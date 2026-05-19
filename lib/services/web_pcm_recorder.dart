import 'package:flutter/foundation.dart';
import 'dart:js_interop';

@JS('startPcmAudioRecording')
external void _startPcmAudioRecording(JSFunction callback);

@JS('stopPcmAudioRecording')
external void _stopPcmAudioRecording();

@JS('playIncomingPcmChunk')
external void _playIncomingPcmChunk(JSString base64Audio);

@JS('stopPcmPlayback')
external void _stopPcmPlayback();

class WebPcmRecorder {
  static void start(void Function(String base64Audio) onAudioChunk) {
    if (kIsWeb) {
      void wrapper(JSString chunk) {
        onAudioChunk(chunk.toDart);
      }
      _startPcmAudioRecording(wrapper.toJS);
    }
  }

  static void stop() {
    if (kIsWeb) {
      _stopPcmAudioRecording();
    }
  }

  static void playChunk(String base64Audio) {
    if (kIsWeb) {
      _playIncomingPcmChunk(base64Audio.toJS);
    }
  }

  static void stopPlayback() {
    if (kIsWeb) {
      _stopPcmPlayback();
    }
  }
}

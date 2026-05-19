import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'package:fftea/fftea.dart';

/// Models the result returned from the Acoustic Isolate
class AcousticDiagnostics {
  final double maxDb;
  final double peakFrequency;
  final bool isRedFlag;

  AcousticDiagnostics({
    required this.maxDb,
    required this.peakFrequency,
    required this.isRedFlag,
  });
}

class AudioDiagnosticService {
  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioStreamSub;

  // Buffering for Vertex AI/Gemini
  final List<int> _buffer3sec = [];
  // 16kHz * 1 channel * 2 bytes (16-bit PCM) * 3 seconds
  static const int _targetBufferBytes = 16000 * 1 * 2 * 3; 

  // Isolate communication
  Isolate? _analyzerIsolate;
  SendPort? _isolateSendPort;
  ReceivePort? _isolateReceivePort;

  // Callbacks for UI
  final void Function(AcousticDiagnostics) onLocalSpikeDetected;
  final void Function(Uint8List) onGeminiChunkReady;

  AudioDiagnosticService({
    required this.onLocalSpikeDetected,
    required this.onGeminiChunkReady,
  });

  /// Initializes the isolate for FFT processing
  Future<void> initIsolate() async {
    _isolateReceivePort = ReceivePort();
    _analyzerIsolate = await Isolate.spawn(
      _diagnosticIsolateEntryPoint,
      _isolateReceivePort!.sendPort,
      debugName: 'AcousticDiagnosticIsolate',
    );

    // Listen to messages from the isolate
    _isolateReceivePort!.listen((message) {
      if (message is SendPort) {
        _isolateSendPort = message;
      } else if (message is AcousticDiagnostics) {
        // We received immediate local feedback!
        onLocalSpikeDetected(message);
      }
    });
  }

  Future<void> startListening() async {
    if (await _audioRecorder.hasPermission()) {
      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      _audioStreamSub = stream.listen((Uint8List data) {
        _handleIncomingAudio(data);
      });
    }
  }

  void _handleIncomingAudio(Uint8List data) {
    if (_isolateSendPort != null) {
      _isolateSendPort!.send(data);
    }

    _buffer3sec.addAll(data);

    if (_buffer3sec.length >= _targetBufferBytes) {
      final chunkReady = Uint8List.fromList(_buffer3sec);
      _buffer3sec.clear();
      onGeminiChunkReady(chunkReady);
    }
  }

  Future<void> stopListening() async {
    await _audioStreamSub?.cancel();
    await _audioRecorder.stop();
    await _audioRecorder.dispose();
    
    _isolateReceivePort?.close();
    _analyzerIsolate?.kill(priority: Isolate.immediate);
  }
}

/// ------------------------------------------------------------------
/// ISOLATE ENTRY POINT (Runs on separate thread to keep UI at 60fps)
/// ------------------------------------------------------------------
void _diagnosticIsolateEntryPoint(SendPort mainSendPort) {
  final isolateReceivePort = ReceivePort();
  mainSendPort.send(isolateReceivePort.sendPort);

  // We are processing frames dynamically based on chunk sizes coming from the mic.
  // Record plugin typically gives chunks of varying length, we must process them.
  final stft = STFT(1024);

  isolateReceivePort.listen((message) {
    if (message is Uint8List) {
      double rms = 0.0;
      double maxAmplitude = 0.0;
      
      final byteData = ByteData.view(message.buffer);
      final int numSamples = message.length ~/ 2;
      final List<double> audioSamples = List<double>.filled(numSamples, 0.0);

      for (int i = 0; i < message.length; i += 2) {
        final sample = byteData.getInt16(i, Endian.little).toDouble();
        audioSamples[i ~/ 2] = sample;
        
        rms += (sample * sample);
        if (sample.abs() > maxAmplitude) {
          maxAmplitude = sample.abs();
        }
      }
      
      rms = sqrt(rms / numSamples);
      final dbfs = rms == 0 ? -100.0 : 20 * (log(rms / 32768) / ln10);

      double maxMagnitude = 0;
      double peakFreq = 0;

      // Ensure STFT only runs on buffer >= 1024
      if (audioSamples.length >= 1024) {
         stft.run(audioSamples, (Float64x2List freqDomain) {
            // Analyze magnitudes 
            for (int i = 0; i < freqDomain.length; i++) {
              final magnitude = freqDomain[i].x * freqDomain[i].x + freqDomain[i].y * freqDomain[i].y;
              if (magnitude > maxMagnitude) {
                maxMagnitude = magnitude;
                // Calculate actual frequency : Bin index * Sample Rate / FFT Size
                peakFreq = i * 16000.0 / 1024.0;
              }
            }
         });
      }

      // RED FLAG LOGIC:
      // High-pitched squeal typical of bearing failure ~3kHz-5kHz.
      bool isRedFlag = false;
      if (dbfs > -20.0 && (peakFreq >= 3000 && peakFreq <= 5000)) {
        isRedFlag = true;
      }

      mainSendPort.send(AcousticDiagnostics(
        maxDb: dbfs,
        peakFrequency: peakFreq,
        isRedFlag: isRedFlag,
      ));
    }
  });
}

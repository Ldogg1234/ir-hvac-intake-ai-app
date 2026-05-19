import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:fftea/fftea.dart';

// Represents the data sent from main isolate to background isolate
class AudioProcessData {
  final Uint8List pcmData;
  final int sampleRate; // Usually 16000
  
  AudioProcessData(this.pcmData, this.sampleRate);
}

// Represents the diagnostic result sent back to main isolate
class DiagnosticTrigger {
  final bool isDangerousDb;
  final bool isHighFrequencyWhistle;
  final double dbFS;
  final double peakHz;

  DiagnosticTrigger({
    required this.isDangerousDb,
    required this.isHighFrequencyWhistle,
    required this.dbFS,
    required this.peakHz,
  });
}

// The background isolate entry point
void safetyAudioIsolate(SendPort sendPort) {
  final port = ReceivePort();
  sendPort.send(port.sendPort);

  // Initialize FFT - typical chunk size from record is ~2048 or 4096 bytes (1024 or 2048 samples)
  // We'll dynamically allocate the FFT object based on incoming array length if needed,
  // but a typical audio packet is 1024 frames.

  port.listen((message) {
    if (message is AudioProcessData) {
      final pcmBytes = message.pcmData;
      final numSamples = pcmBytes.length ~/ 2;
      
      // Safety check for empty or too-small buffers
      if (numSamples < 2) return;

      // Convert 16-bit PCM bytes to Float64 format for FFT & RMS
      final audioSamples = Float64List(numSamples);
      final byteData = pcmBytes.buffer.asByteData(pcmBytes.offsetInBytes, pcmBytes.lengthInBytes);

      double sumOfSquares = 0.0;
      
      for (int i = 0; i < numSamples; i++) {
        // Read 16-bit signed integer (little-endian typically from mobile mics)
        int sample16 = byteData.getInt16(i * 2, Endian.little);
        
        // Normalize to -1.0 .. 1.0
        double normalized = sample16 / 32768.0;
        audioSamples[i] = normalized;
        sumOfSquares += (normalized * normalized);
      }

      // 1. Calculate dBFS (Root Mean Square)
      double rms = sqrt(sumOfSquares / numSamples);
      // Avoid log10 of 0
      double dbFS = rms > 0 ? 20 * (log(rms) / ln10) : -100.0;

      // 2. Calculate Peak Frequency using fftea
      // We only run FFT if the buffer size is a power of 2, or we pad it.
      // Easiest is to truncate to the nearest power of 2
      int pow2Size = 1;
      while (pow2Size * 2 <= numSamples) {
        pow2Size *= 2;
      }
      
      double peakHz = 0.0;
      if (pow2Size >= 256) {
        final fftSamples = Float64List(pow2Size);
        for (int i=0; i<pow2Size; i++) fftSamples[i] = audioSamples[i];
        
        final fft = FFT(pow2Size);
        final spectrum = fft.realFft(fftSamples);
        final magnitudes = spectrum.magnitudes();
        
        double maxMag = 0;
        int maxIndex = 0;
        // Search up to Nyquist frequency (length/2)
        for (int i = 0; i < magnitudes.length; i++) {
          if (magnitudes[i] > maxMag) {
            maxMag = magnitudes[i];
            maxIndex = i;
          }
        }
        
        // Calculate the frequency of the peak magnitude
        peakHz = maxIndex * (message.sampleRate / pow2Size);
      }

      // 3. Evaluate Thresholds
      // Example safety thresholds:
      // dBFS > -5.0 is practically clipping/extremely loud close to the mic
      bool isDangerous = dbFS > -5.0; 
      // Bearing squeal threshold: High frequency (3000 - 5000 Hz) and loud enough to not be background noise (> -20 dBFS)
      bool isWhistle = peakHz >= 3000.0 && peakHz <= 5000.0 && dbFS > -20.0;

      // If either event happens, optionally notify the main thread immediately
      // We only send significant triggers to avoid spamming the main thread.
      if (isDangerous || isWhistle) {
        sendPort.send(DiagnosticTrigger(
          isDangerousDb: isDangerous,
          isHighFrequencyWhistle: isWhistle,
          dbFS: dbFS,
          peakHz: peakHz,
        ));
      }
    }
  });
}

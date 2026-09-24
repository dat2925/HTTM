import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();

  Future<void> initialize() async {
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(false);
    try {
      await _tts.setLanguage('vi-VN');
    } catch (_) {
      // The device default voice is a safe fallback when Vietnamese is absent.
    }
  }

  Future<void> speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> dispose() => _tts.stop();
}

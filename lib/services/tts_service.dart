import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  int _request = 0;
  int _priority = 0;
  DateTime? _priorityUntil;

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

  Future<bool> speak(String text, {int priority = 2}) async {
    final now = DateTime.now();
    if (_priorityUntil != null &&
        now.isBefore(_priorityUntil!) &&
        priority < _priority) {
      return false;
    }
    final request = ++_request;
    _priority = priority;
    _priorityUntil = now.add(
      Duration(seconds: (text.length / 10).ceil().clamp(3, 25)),
    );
    await _tts.stop();
    if (request != _request) return false;
    await _tts.speak(text);
    return true;
  }

  Future<void> silence() async {
    ++_request;
    _priority = 0;
    _priorityUntil = null;
    await _tts.stop();
  }

  Future<void> dispose() => silence();
}

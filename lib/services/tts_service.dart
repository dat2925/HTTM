import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

/// One voice shared by several speakers: assistant (0), route guidance (1),
/// status (2), obstacle warnings (3) and prompts the user must answer (4).
///
/// A new sentence does not cut off a different speaker; it waits for the
/// current sentence to end. It replaces the current sentence only when it
/// comes from the same speaker (newer information), when the caller asks to
/// [speak] with `interrupt`, or when the assistant (0) is talking.
class TtsService {
  final FlutterTts _tts = FlutterTts();
  int _request = 0;
  int? _speakingPriority;
  Timer? _doneTimer;
  ({String text, int priority, DateTime at})? _queued;

  /// A queued sentence older than this is stale and is dropped, not spoken.
  static const Duration maxQueueWait = Duration(seconds: 6);

  Future<void> initialize() async {
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(false);
    // Fires only when a sentence ends by itself; stop() reports a cancel.
    _tts.setCompletionHandler(() => _finished(_request));
    try {
      await _tts.setLanguage('vi-VN');
    } catch (_) {
      // The device default voice is a safe fallback when Vietnamese is absent.
    }
  }

  /// Returns true when the sentence was started or queued behind the current
  /// one, false when it could not be spoken or was superseded.
  Future<bool> speak(
    String text, {
    int priority = 2,
    bool interrupt = false,
  }) async {
    final speaking = _speakingPriority;
    if (speaking != null &&
        !interrupt &&
        speaking != 0 &&
        speaking != priority) {
      final queued = _queued;
      if (queued == null || priority >= queued.priority) {
        _queued = (text: text, priority: priority, at: DateTime.now());
      }
      return true;
    }
    return _start(text, priority);
  }

  Future<bool> _start(String text, int priority) async {
    final request = ++_request;
    _speakingPriority = priority;
    _doneTimer?.cancel();
    // Fallback for engines that never report completion.
    _doneTimer = Timer(_estimate(text), () => _finished(request));
    try {
      await _tts.stop();
      if (request != _request) return false;
      await _tts.speak(text);
      return true;
    } catch (_) {
      _finished(request);
      return false;
    }
  }

  static Duration _estimate(String text) => Duration(
    milliseconds: (1000 + text.length * 110).clamp(2000, 25000).toInt(),
  );

  void _finished(int request) {
    if (request != _request) return;
    _doneTimer?.cancel();
    _doneTimer = null;
    _speakingPriority = null;
    final queued = _queued;
    _queued = null;
    if (queued != null &&
        DateTime.now().difference(queued.at) <= maxQueueWait) {
      unawaited(_start(queued.text, queued.priority));
    }
  }

  Future<void> silence() async {
    ++_request;
    _doneTimer?.cancel();
    _doneTimer = null;
    _speakingPriority = null;
    _queued = null;
    try {
      await _tts.stop();
    } catch (_) {
      // Audio may be unavailable while the remaining device services recover.
    }
  }

  Future<void> dispose() => silence();
}

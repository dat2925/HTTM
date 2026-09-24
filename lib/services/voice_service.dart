import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart';

class VoiceException implements Exception {
  const VoiceException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Thin wrapper around `speech_to_text` for the press-and-hold talk button.
/// Recognition only — no intent/route handling exists yet, callers just show
/// whatever text comes back.
class VoiceService {
  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;
  String _lastResult = '';
  Completer<String?>? _finalResultCompleter;

  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _speech.initialize(
      onError: (error) => _finalResultCompleter?.complete(null),
    );
    return _initialized;
  }

  Future<void> startListening({void Function(String text)? onResult}) async {
    if (!await initialize()) {
      throw const VoiceException(
        'Không thể dùng nhận dạng giọng nói (thiếu quyền micro hoặc thiết '
        'bị không hỗ trợ).',
      );
    }
    _lastResult = '';
    _finalResultCompleter = null;
    await _speech.listen(
      onResult: (result) {
        _lastResult = result.recognizedWords;
        onResult?.call(_lastResult);
        // The true final transcript from the recognizer arrives via this
        // same callback, asynchronously *after* stop() has already been
        // called — stopListening() below waits for it instead of racing
        // ahead and reading whatever partial text happened to land first.
        if (result.finalResult) {
          _finalResultCompleter?.complete(
            _lastResult.isEmpty ? null : _lastResult,
          );
        }
      },
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.confirmation,
        localeId: 'vi_VN',
      ),
    );
  }

  Future<String?> stopListening() async {
    if (!_speech.isListening) {
      return _lastResult.isEmpty ? null : _lastResult;
    }
    final completer = Completer<String?>();
    _finalResultCompleter = completer;
    await _speech.stop();
    return completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => _lastResult.isEmpty ? null : _lastResult,
    );
  }

  void dispose() {
    _speech.cancel();
  }
}

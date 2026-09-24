import 'package:speech_to_text/speech_to_text.dart';

/// Thin wrapper around `speech_to_text` for the press-and-hold talk button.
/// Recognition only — no intent/route handling exists yet, callers just show
/// whatever text comes back.
class VoiceService {
  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;
  String _lastResult = '';

  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _speech.initialize();
    return _initialized;
  }

  Future<void> startListening({void Function(String text)? onResult}) async {
    if (!await initialize()) return;
    _lastResult = '';
    await _speech.listen(
      onResult: (result) {
        _lastResult = result.recognizedWords;
        onResult?.call(_lastResult);
      },
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.confirmation,
        localeId: 'vi_VN',
      ),
    );
  }

  Future<String?> stopListening() async {
    await _speech.stop();
    return _lastResult.isEmpty ? null : _lastResult;
  }

  void dispose() {
    _speech.cancel();
  }
}

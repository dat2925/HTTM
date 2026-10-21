import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

import '../config/ai_config.dart';
import '../models/detection_result.dart';
import '../models/perception_frame.dart';
import '../models/session_state.dart';
import '../services/ai_detection_service.dart';
import '../services/frame_source.dart';
import '../services/obstacle_reasoning_service.dart';
import '../services/tts_service.dart';
import '../services/voice_command_router.dart';
import '../services/voice_service.dart';

class DeviceSessionException implements Exception {
  const DeviceSessionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Owns device resources only. Navigation and assistant modules attach through
/// [onVoiceCommand], [speakGuidance], [speakAssistant], and the QR camera lease.
class SessionController {
  SessionController({
    FrameSource? frameSource,
    AiDetectionService? detectionService,
    ObstacleReasoningService? reasoningService,
    VoiceService? voiceService,
    TtsService? ttsService,
    this.onVoiceCommand,
    this.onHaptic,
    this.captureInterval = AiConfig.captureInterval,
  }) : _camera = frameSource ?? FrameSource(),
       _detector = detectionService ?? AiDetectionService(),
       _reasoning = reasoningService ?? ObstacleReasoningService(),
       _voice = voiceService ?? VoiceService(),
       _tts = ttsService ?? TtsService();

  final FrameSource _camera;
  final AiDetectionService _detector;
  final ObstacleReasoningService _reasoning;
  final VoiceService _voice;
  final TtsService _tts;
  final FutureOr<void> Function(VoiceCommand command, String text)?
  onVoiceCommand;
  final Future<void> Function(DangerLevel danger)? onHaptic;
  final Duration captureInterval;
  final _states = StreamController<SessionState>.broadcast();
  final _frames = StreamController<PerceptionFrame>.broadcast();
  final _listening = StreamController<bool>.broadcast();
  SessionState _state = const SessionIdle();
  Future<void> _cameraWork = Future.value();
  Future<void>? _initialization, _pauseWork, _listeningStart;
  Timer? _timer;
  bool _running = false, _busy = false, _disposed = false;
  bool _paused = false, _cameraBorrowed = false, _restartAfterPause = false;
  bool _isListening = false, _endingTalk = false, _alerting = false;
  int _epoch = 0, _voiceEpoch = 0, _emptyCycles = 0;
  String? _lastWarning;
  DateTime? _lastWarningAt;
  DangerLevel? _lastDanger;
  String? cameraError, lastUtterance;
  VoiceCommandKind? lastCommandKind;

  Stream<SessionState> get states => _states.stream;
  Stream<PerceptionFrame> get frames => _frames.stream;
  Stream<bool> get listening => _listening.stream;
  SessionState get state => _state;
  CameraController? get cameraController => _camera.controller;
  bool get isRunning => _running;
  bool get isListening => _isListening;

  void _publish(SessionState state) {
    if (_disposed) return;
    _state = state;
    _states.add(state);
  }

  // Serialize native camera work, without waiting for the HTTP inference reply.
  Future<T> _useCamera<T>(Future<T> Function() action) {
    final result = _cameraWork.then((_) => action());
    _cameraWork = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await _tts.initialize();
    if (_disposed || _paused || _cameraBorrowed) return;
    await _openCamera();
  }

  Future<bool> _openCamera() async {
    try {
      await _useCamera(() async {
        if (!_disposed && !_paused && !_cameraBorrowed && !_camera.isReady) {
          await _camera.initialize();
        }
      });
      if (_disposed || _paused || _cameraBorrowed) return false;
      cameraError = null;
      return _camera.isReady;
    } catch (_) {
      cameraError = 'Camera chưa sẵn sàng. Hãy kiểm tra quyền camera.';
      _publish(SessionRunning(statusText: cameraError!));
      return false;
    }
  }

  Future<bool> start() async {
    if (_disposed || _paused || _cameraBorrowed || _running) return false;
    await initialize();
    if (!_camera.isReady && !await _openCamera()) return false;
    final epoch = _epoch;
    final healthy = await _detector.isHealthy();
    if (_disposed ||
        _paused ||
        _cameraBorrowed ||
        _running ||
        epoch != _epoch) {
      return false;
    }
    if (!healthy) {
      cameraError = 'Không kết nối được AI Server.';
      _publish(SessionRunning(statusText: cameraError!));
      return false;
    }
    cameraError = null;
    _running = true;
    _publish(const SessionRunning(statusText: 'AI đang chạy'));
    _timer = Timer.periodic(
      captureInterval,
      (_) => unawaited(_captureAndDetect()),
    );
    unawaited(_captureAndDetect());
    return true;
  }

  void stop() {
    ++_epoch;
    _timer?.cancel();
    _timer = null;
    _running = false;
    _alerting = false;
    _emptyCycles = 0;
    _lastWarning = null;
    _lastWarningAt = null;
    _lastDanger = null;
    _publish(const SessionIdle(statusText: 'AI đã dừng'));
  }

  bool _valid(int epoch) => !_disposed && _running && epoch == _epoch;

  Future<void> _captureAndDetect() async {
    if (!_running ||
        _disposed ||
        _busy ||
        _cameraBorrowed ||
        !_camera.isReady) {
      return;
    }
    _busy = true;
    final epoch = _epoch;
    final startedAt = DateTime.now();
    XFile? image;
    try {
      image = await _useCamera(() async {
        if (!_valid(epoch) || _cameraBorrowed) return null;
        return _camera.captureFrame();
      });
      if (image == null || !_valid(epoch)) return;
      final result = await _detector.detect(image);
      if (!_valid(epoch)) return;
      cameraError = null;
      final latency = DateTime.now().difference(startedAt).inMilliseconds;
      _frames.add(
        PerceptionFrame(
          objects: result.objects,
          imageWidth: result.imageWidth,
          imageHeight: result.imageHeight,
          fps: latency > 0 ? 1000 / latency : 0,
          latencyMs: latency,
        ),
      );
      await _processResult(result, epoch);
    } catch (error) {
      if (!_valid(epoch)) return;
      cameraError = error is AiDetectionException
          ? error.message
          : 'Lỗi chụp ảnh hoặc nhận diện. Hệ thống sẽ thử lại.';
      _publish(SessionRunning(statusText: cameraError!));
    } finally {
      _busy = false;
      if (image != null && image.path.isNotEmpty) {
        try {
          await File(image.path).delete();
        } catch (_) {
          // Cleanup must not interrupt perception.
        }
      }
    }
  }

  Future<void> _processResult(DetectionResult result, int epoch) async {
    final warning = _reasoning.selectWarning(result.objects);
    if (warning == null) {
      if (++_emptyCycles < AiConfig.safeCyclesRequired) return;
      final hadWarning = _alerting;
      _alerting = false;
      _publish(
        const SessionRunning(statusText: 'Chưa phát hiện vật cản phía trước.'),
      );
      if (hadWarning && !_isListening && _valid(epoch)) {
        await _tts.speak('Chưa phát hiện vật cản phía trước.', priority: 3);
      }
      return;
    }
    _emptyCycles = 0;
    _alerting = true;
    _publish(
      SessionAlerting(
        statusText: warning.text,
        objectName: warning.object.className,
        danger: warning.danger,
      ),
    );
    final now = DateTime.now();
    final coolingDown =
        _lastWarning == warning.text &&
        _lastWarningAt != null &&
        now.difference(_lastWarningAt!) < AiConfig.warningCooldown;
    final urgent =
        warning.danger == DangerLevel.high && _lastDanger != DangerLevel.high;
    if (coolingDown && !urgent) return;
    if (onHaptic != null) {
      await onHaptic!(warning.danger);
    } else if (warning.danger == DangerLevel.high) {
      await HapticFeedback.heavyImpact();
    } else if (warning.danger == DangerLevel.medium) {
      await HapticFeedback.mediumImpact();
    }
    if (!_valid(epoch) || _isListening) return;
    if (await _tts.speak(warning.text, priority: 3)) {
      _lastWarning = warning.text;
      _lastWarningAt = now;
      _lastDanger = warning.danger;
    }
  }

  /// Integration points: lower-priority speech never preempts an obstacle.
  Future<bool> speakAssistant(String text) => _speakExternal(text, 0);
  Future<bool> speakGuidance(String text) => _speakExternal(text, 1);
  Future<bool> _speakExternal(String text, int priority) async {
    if (_disposed || _paused || _isListening || _alerting) return false;
    return _tts.speak(text, priority: priority);
  }

  Future<void> onTalkStart() async {
    if (_disposed || _paused || _isListening || _endingTalk) return;
    _isListening = true;
    _listening.add(true);
    final epoch = ++_voiceEpoch;
    try {
      _listeningStart = _beginListening(epoch);
      await _listeningStart;
    } catch (_) {
      if (_disposed || epoch != _voiceEpoch) return;
      _isListening = false;
      _listening.add(false);
      _publish(
        const SessionRunning(
          statusText: 'Không thể dùng micro. Hãy kiểm tra quyền ghi âm.',
        ),
      );
    } finally {
      _listeningStart = null;
    }
  }

  Future<void> _beginListening(int epoch) async {
    await _tts.silence();
    if (_disposed || _paused || epoch != _voiceEpoch) return;
    await _voice.startListening(
      onResult: (text) {
        if (!_disposed && epoch == _voiceEpoch) {
          _publish(SessionRunning(statusText: 'Đang nghe: $text'));
        }
      },
    );
  }

  Future<void> onTalkEnd() async {
    if (_disposed || !_isListening || _endingTalk) return;
    _endingTalk = true;
    final epoch = _voiceEpoch;
    try {
      await _listeningStart;
      if (_disposed || _paused || epoch != _voiceEpoch || !_isListening) return;
      final text = await _voice.stopListening();
      if (_disposed || _paused || epoch != _voiceEpoch) return;
      _isListening = false;
      _listening.add(false);
      if (text != null && text.trim().isNotEmpty) {
        await handleUtterance(text);
      }
    } catch (_) {
      if (!_disposed && epoch == _voiceEpoch) {
        _publish(
          const SessionRunning(
            statusText: 'Không nhận được giọng nói. Hãy thử lại.',
          ),
        );
      }
    } finally {
      if (!_disposed && epoch == _voiceEpoch && _isListening) {
        _isListening = false;
        _listening.add(false);
      }
      _endingTalk = false;
    }
  }

  Future<void> handleUtterance(String text) async {
    if (_disposed || _paused || text.trim().isEmpty) return;
    lastUtterance = text.trim();
    final command = VoiceCommand.parse(text);
    lastCommandKind = command.kind;
    _publish(SessionRunning(statusText: 'Đã nghe: $lastUtterance'));
    await onVoiceCommand?.call(command, lastUtterance!);
  }

  Future<void> pause() {
    if (_disposed) return Future.value();
    if (_paused) return _pauseWork ?? Future.value();
    _paused = true;
    _restartAfterPause = _running;
    ++_voiceEpoch;
    _isListening = false;
    _listening.add(false);
    stop();
    return _pauseWork = _pauseHardware();
  }

  Future<void> _pauseHardware() async {
    await _tts.silence();
    try {
      await _listeningStart;
    } catch (_) {
      // A failed recognition startup must not prevent releasing the camera.
    }
    await _voice.cancelListening();
    await _useCamera(_camera.dispose);
  }

  Future<void> resume() async {
    await _pauseWork;
    if (_disposed) return;
    _paused = false;
    if (_cameraBorrowed) return;
    await initialize();
    await _openCamera();
    if (_restartAfterPause) {
      _restartAfterPause = false;
      await start();
    }
  }

  /// Called before the QR owner opens its scanner. No QR decoding/auth is here.
  Future<bool> suspendCameraForQr() async {
    if (_disposed || _paused || _cameraBorrowed || _isListening) {
      throw const DeviceSessionException('Camera hoặc micro đang bận.');
    }
    final wasRunning = _running;
    _cameraBorrowed = true;
    stop();
    try {
      await _useCamera(_camera.dispose);
      _publish(
        const SessionRunning(statusText: 'Camera đang được dùng để quét QR.'),
      );
      return wasRunning;
    } catch (_) {
      _cameraBorrowed = false;
      if (wasRunning && !_disposed && !_paused) unawaited(start());
      throw const DeviceSessionException('Chưa nhường được camera cho QR.');
    }
  }

  /// Call only after the QR scanner has finished disposing its native camera.
  Future<void> resumeCameraAfterQr({required bool restartPerception}) async {
    if (_disposed || !_cameraBorrowed) return;
    _cameraBorrowed = false;
    if (_paused) {
      _restartAfterPause = _restartAfterPause || restartPerception;
      return;
    }
    if (!await _openCamera()) return;
    if (restartPerception) await start();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_voiceEpoch;
    stop();
    try {
      await _initialization;
      await _pauseWork;
      await _listeningStart;
    } catch (_) {
      // Release the remaining resources even if initialization failed.
    }
    await _voice.cancelListening();
    await _useCamera(_camera.dispose);
    _detector.dispose();
    _voice.dispose();
    await _tts.dispose();
    await _states.close();
    await _frames.close();
    await _listening.close();
  }
}

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
import '../services/route_service.dart';
import '../services/tts_service.dart';
import '../services/voice_service.dart';

/// Conductor tying the camera/YOLO perception loop, the GPS route heuristic,
/// the talk button, and TTS output into one place the UI just observes.
class SessionController {
  SessionController({
    FrameSource? frameSource,
    AiDetectionService? detectionService,
    ObstacleReasoningService? reasoningService,
    RouteService? routeService,
    VoiceService? voiceService,
    TtsService? ttsService,
  }) : _frameSource = frameSource ?? FrameSource(),
       _detectionService = detectionService ?? AiDetectionService(),
       _reasoningService = reasoningService ?? ObstacleReasoningService(),
       _routeService =
           routeService ??
           GeolocatorRouteService(
             destinationLat: AiConfig.demoDestinationLat,
             destinationLng: AiConfig.demoDestinationLng,
           ),
       _voiceService = voiceService ?? VoiceService(),
       _ttsService = ttsService ?? TtsService();

  final FrameSource _frameSource;
  final AiDetectionService _detectionService;
  final ObstacleReasoningService _reasoningService;
  final RouteService _routeService;
  final VoiceService _voiceService;
  final TtsService _ttsService;

  final StreamController<SessionState> _stateController =
      StreamController<SessionState>.broadcast();
  final StreamController<PerceptionFrame> _frameController =
      StreamController<PerceptionFrame>.broadcast();
  final StreamController<bool> _listeningController =
      StreamController<bool>.broadcast();

  Timer? _captureTimer;
  StreamSubscription<RouteInstruction>? _routeSubscription;
  bool _running = false;
  bool _requestInProgress = false;
  String? _lastSpokenWarning;
  DateTime? _lastSpokenAt;
  DangerLevel? _lastSpokenDanger;
  int _emptyCycles = 0;
  bool _wasDangerous = false;
  RouteInstruction? _lastRoute;
  bool _isListening = false;

  Stream<SessionState> get states => _stateController.stream;
  Stream<PerceptionFrame> get frames => _frameController.stream;
  Stream<bool> get listening => _listeningController.stream;
  CameraController? get cameraController => _frameSource.controller;
  bool get isRunning => _running;

  Future<void> initialize() async {
    await _frameSource.initialize();
    await _ttsService.initialize();
    _routeSubscription = _routeService.instructions.listen((instruction) {
      _lastRoute = instruction;
    });
    _routeService.start();
  }

  Future<bool> start() async {
    if (_running || !_frameSource.isReady) return false;
    final healthy = await _detectionService.isHealthy();
    if (!healthy) {
      _stateController.add(
        const SessionRunning(statusText: 'Không thể kết nối AI Server.'),
      );
      return false;
    }
    _running = true;
    _stateController.add(const SessionRunning(statusText: 'AI đang chạy'));
    _captureTimer = Timer.periodic(
      AiConfig.captureInterval,
      (_) => _captureAndDetect(),
    );
    unawaited(_captureAndDetect());
    return true;
  }

  void stop() {
    _captureTimer?.cancel();
    _captureTimer = null;
    _running = false;
    _stateController.add(const SessionRunning(statusText: 'AI đã dừng'));
  }

  Future<void> _captureAndDetect() async {
    if (!_running || _requestInProgress || !_frameSource.isReady) return;
    _requestInProgress = true;
    final startedAt = DateTime.now();
    XFile? image;
    try {
      image = await _frameSource.captureFrame();
      final result = await _detectionService.detect(image);
      final latencyMs = DateTime.now().difference(startedAt).inMilliseconds;
      final fps = latencyMs > 0 ? 1000 / latencyMs : 0.0;
      _frameController.add(
        PerceptionFrame(
          objects: result.objects,
          imageWidth: result.imageWidth,
          imageHeight: result.imageHeight,
          fps: fps,
          latencyMs: latencyMs,
        ),
      );
      await _processResult(result);
    } on CameraException {
      if (_running) {
        _stateController.add(
          const SessionRunning(statusText: 'Lỗi chụp ảnh từ camera.'),
        );
      }
    } on AiDetectionException catch (error) {
      if (_running) {
        _stateController.add(SessionRunning(statusText: error.message));
      }
    } finally {
      _requestInProgress = false;
      if (image != null) {
        try {
          await File(image.path).delete();
        } catch (_) {
          // Camera cache cleanup is best-effort only.
        }
      }
    }
  }

  Future<void> _processResult(DetectionResult result) async {
    final warning = _reasoningService.selectWarning(result.objects);
    final routeText = _lastRoute?.text;

    if (warning == null) {
      _emptyCycles++;
      if (_emptyCycles >= AiConfig.safeCyclesRequired) {
        final shouldSpeakSafe = _wasDangerous;
        _wasDangerous = false;
        _stateController.add(
          SessionRunning(
            statusText: 'Phía trước chưa phát hiện vật cản.',
            subStatusText: routeText == null ? null : 'Route: $routeText',
          ),
        );
        if (shouldSpeakSafe) {
          await _ttsService.speak('Phía trước an toàn.');
          _lastSpokenWarning = 'Phía trước an toàn.';
          _lastSpokenAt = DateTime.now();
          _lastSpokenDanger = null;
        }
      }
      return;
    }

    _emptyCycles = 0;
    _wasDangerous = true;
    final decisionSource = routeText == null
        ? 'Camera: ${_positionLabel(warning.object.position)} bị chắn'
        : 'Route: $routeText · Camera: ${_positionLabel(warning.object.position)} bị chắn';
    _stateController.add(
      SessionAlerting(
        statusText: warning.text,
        subStatusText: decisionSource,
        objectName: warning.object.className,
        danger: warning.danger,
      ),
    );

    final now = DateTime.now();
    final sameWarningCoolingDown =
        _lastSpokenWarning == warning.text &&
        _lastSpokenAt != null &&
        now.difference(_lastSpokenAt!) < AiConfig.warningCooldown;
    final canInterrupt =
        warning.danger == DangerLevel.high &&
        _lastSpokenDanger != DangerLevel.high;
    if (!sameWarningCoolingDown || canInterrupt) {
      if (warning.danger == DangerLevel.high) {
        await HapticFeedback.heavyImpact();
      } else if (warning.danger == DangerLevel.medium) {
        await HapticFeedback.mediumImpact();
      }
      await _ttsService.speak(warning.text);
      _lastSpokenWarning = warning.text;
      _lastSpokenAt = now;
      _lastSpokenDanger = warning.danger;
    }
  }

  String _positionLabel(String position) => switch (position) {
    'left' => 'trái',
    'right' => 'phải',
    _ => 'giữa',
  };

  Future<void> onTalkStart() async {
    _isListening = true;
    _listeningController.add(true);
    await _voiceService.startListening(
      onResult: (text) {
        _stateController.add(SessionRunning(statusText: 'Đang nghe: $text'));
      },
    );
  }

  Future<void> onTalkEnd() async {
    final text = await _voiceService.stopListening();
    _isListening = false;
    _listeningController.add(false);
    _stateController.add(
      SessionRunning(
        statusText: _running ? 'AI đang chạy' : 'AI đã dừng',
        subStatusText: text == null ? null : 'Lệnh: $text',
      ),
    );
  }

  bool get isListening => _isListening;

  Future<void> dispose() async {
    _captureTimer?.cancel();
    await _routeSubscription?.cancel();
    _routeService.dispose();
    await _frameSource.dispose();
    _detectionService.dispose();
    _voiceService.dispose();
    await _ttsService.dispose();
    await _stateController.close();
    await _frameController.close();
    await _listeningController.close();
  }
}

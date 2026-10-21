import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

import '../config/ai_config.dart';
import '../models/detection_result.dart';
import '../models/perception_frame.dart';
import '../models/route_progress.dart';
import '../models/placemark.dart';
import '../models/geo_point.dart';
import '../models/session_state.dart';
import '../services/ai_detection_service.dart';
import '../services/frame_source.dart';
import '../services/geocoding_service.dart';
import '../services/obstacle_reasoning_service.dart';
import '../services/route_service.dart';
import '../services/tts_service.dart';
import '../services/voice_service.dart';
import '../services/voice_command_router.dart';
import '../services/assistant_service.dart';
import '../models/assistant_state.dart';
import 'assistant_controller.dart';

/// Conductor tying the camera/YOLO perception loop, pedestrian navigation,
/// the talk button, and TTS output into one place the UI just observes.
class SessionController {
  SessionController({
    FrameSource? frameSource,
    AiDetectionService? detectionService,
    ObstacleReasoningService? reasoningService,
    RouteService? routeService,
    VoiceService? voiceService,
    TtsService? ttsService,
    GeocodingService? geocodingService,
    AiAssistantService? assistantService,
  }) : _frameSource = frameSource ?? FrameSource(),
       _detectionService = detectionService ?? AiDetectionService(),
       _reasoningService = reasoningService ?? ObstacleReasoningService(),
       _routeService = routeService ?? PedestrianRouteService(),
       _voiceService = voiceService ?? VoiceService(),
       _ttsService = ttsService ?? TtsService(),
       _geocodingService = geocodingService ?? GeocodingService(),
       _assistantService = assistantService ?? AiAssistantService();

  final FrameSource _frameSource;
  final AiDetectionService _detectionService;
  final ObstacleReasoningService _reasoningService;
  final RouteService _routeService;
  final VoiceService _voiceService;
  final TtsService _ttsService;
  final GeocodingService _geocodingService;
  final AiAssistantService _assistantService;
  List<DetectedObject> _latestObjects = const [];
  DateTime? _yoloAt;
  Uint8List? _latestJpeg;
  DateTime? _jpegAt;
  late final AssistantController assistant = AssistantController(
    service: _assistantService,
    snapshot: () => routeSnapshot,
    detections: () => _latestObjects,
    yoloUpdatedAt: () => _yoloAt,
    captureImage: _assistantImage,
    onConfirmed: _performAssistantAction,
    speak: (text) => _ttsService.speak(text, priority: 0),
    canSpeak: () =>
        !_disposed &&
        !_cameraBorrowed &&
        !_navigationPaused &&
        !_isListening &&
        !_wasDangerous &&
        (_obstacleUntil == null || DateTime.now().isAfter(_obstacleUntil!)) &&
        (_lastRouteSpokenAt == null ||
            DateTime.now().difference(_lastRouteSpokenAt!) >
                const Duration(seconds: 8)),
    canProactivelyRequest: () =>
        !_disposed &&
        !_cameraBorrowed &&
        !_navigationPaused &&
        !_isListening &&
        !_wasDangerous &&
        _pendingDestination == null,
  );

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
  bool _disposed = false;
  String? _lastRouteKey;
  DateTime? _lastRouteSpokenAt;
  DateTime? _obstacleUntil;
  Timer? _routeSpeechTimer;
  int _destinationRequest = 0;
  String? cameraError;
  Placemark? _pendingDestination;
  String? currentAddress;
  GeoPoint? _addressPosition;
  bool _locatingAddress = false;
  bool _navigationPaused = false;
  Future<void>? _listeningStart;
  bool _cameraBorrowed = false;
  Completer<void>? _cameraIdle;
  Future<void> _cameraWork = Future.value();
  Future<void>? _initialization, _pauseWork;
  int _perceptionEpoch = 0;
  int _navigationLifecycle = 0;
  String? lastUtterance;
  VoiceCommandKind? lastCommandKind;

  Stream<SessionState> get states => _stateController.stream;
  Stream<PerceptionFrame> get frames => _frameController.stream;
  Stream<bool> get listening => _listeningController.stream;
  Stream<RouteProgress> get routeProgress => _routeService.progress;
  RouteProgress get routeSnapshot => _routeService.snapshot;
  Placemark? get pendingDestination => _pendingDestination;
  CameraController? get cameraController => _frameSource.controller;
  bool get isRunning => _running;

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
    await _ttsService.initialize();
    if (_disposed) return;
    unawaited(assistant.initialize());
    _routeSubscription = _routeService.instructions.listen((instruction) {
      _lastRoute = instruction;
      assistant.observe(routeSnapshot);
      if (!_wasDangerous &&
          !_isListening &&
          !_disposed &&
          _pendingDestination == null) {
        _stateController.add(SessionRunning(statusText: instruction.text));
      }
      unawaited(_speakRoute());
    });
    _routeSpeechTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_speakRoute()),
    );
    if (!_navigationPaused) unawaited(_routeService.start());
    await _openCamera();
  }

  Future<void> _openCamera() async {
    try {
      await _useCamera(() async {
        if (!_disposed &&
            !_navigationPaused &&
            !_cameraBorrowed &&
            !_frameSource.isReady) {
          await _frameSource.initialize();
        }
      });
      if (!_disposed && !_navigationPaused && !_cameraBorrowed) {
        cameraError = null;
      }
    } catch (_) {
      cameraError = 'Camera chưa sẵn sàng. Bản đồ và GPS vẫn hoạt động.';
    }
  }

  Future<void> _speakRoute({bool force = false}) async {
    final instruction = _lastRoute;
    final now = DateTime.now();
    if (_disposed ||
        instruction == null ||
        _isListening ||
        _pendingDestination != null ||
        _navigationPaused ||
        routeSnapshot.status == NavigationStatus.paused ||
        (_obstacleUntil != null && now.isBefore(_obstacleUntil!))) {
      return;
    }
    final since = _lastRouteSpokenAt == null
        ? const Duration(days: 1)
        : now.difference(_lastRouteSpokenAt!);
    if (!force &&
        (since < const Duration(seconds: 5) ||
            (_lastRouteKey == instruction.key &&
                since < const Duration(seconds: 25)))) {
      return;
    }
    _lastRouteKey = instruction.key;
    _lastRouteSpokenAt = now;
    final spoken = await _ttsService.speak(instruction.text, priority: 1);
    if (!spoken && _lastRouteSpokenAt == now) {
      _lastRouteSpokenAt = null;
      _lastRouteKey = null;
    }
  }

  Future<void> repeatInstruction() => _speakRoute(force: true);
  Future<void> refreshRoute() => _routeService.refresh();
  Future<void> clearJourney() => _routeService.clearJourney();
  void cancelDestination() {
    assistant.invalidate();
    ++_destinationRequest;
    _pendingDestination = null;
    _routeService.cancelDestination();
  }

  Future<void> resumeNavigation() async {
    final lifecycle = ++_navigationLifecycle;
    await _pauseWork;
    if (_disposed || lifecycle != _navigationLifecycle) return;
    _navigationPaused = false;
    unawaited(_routeService.start());
    if (!_cameraBorrowed) await _openCamera();
  }

  Future<void> pauseNavigation() {
    ++_navigationLifecycle;
    if (_disposed) return Future.value();
    if (_navigationPaused) return _pauseWork ?? Future.value();
    assistant.invalidate();
    _navigationPaused = true;
    stop();
    _routeService.stop();
    return _pauseWork = _pauseHardware();
  }

  Future<void> _pauseHardware() async {
    await _ttsService.silence();
    try {
      await _useCamera(_frameSource.dispose);
    } catch (_) {
      cameraError = 'Chưa giải phóng được camera. Hãy thử lại khi mở ứng dụng.';
    }
  }

  Future<Placemark> findDestination(String query) async {
    final position = routeSnapshot.position;
    return _geocodingService.search(
      query,
      nearLat: position?.lat,
      nearLng: position?.lng,
    );
  }

  Future<bool> navigateTo(Placemark place) async {
    assistant.invalidate();
    ++_destinationRequest;
    _pendingDestination = null;
    _lastRouteKey = null;
    return _routeService.setDestination(
      place.lat,
      place.lng,
      name: place.displayName,
    );
  }

  Future<void> confirmPendingDestination() async {
    final place = _pendingDestination;
    if (place != null) await navigateTo(place);
  }

  void cancelPendingDestination() {
    _pendingDestination = null;
    ++_destinationRequest;
    _stateController.add(SessionRunning(statusText: routeSnapshot.message));
  }

  Future<void> describeLocation() async {
    final progress = routeSnapshot;
    if (progress.position == null) {
      await _ttsService.speak(progress.message);
      return;
    }
    if (progress.updatedAt == null ||
        DateTime.now().difference(progress.updatedAt!) >
            AiConfig.gpsStaleAfter ||
        progress.status == NavigationStatus.poorGps) {
      await _ttsService.speak(
        'Vị trí GPS chưa đủ chính xác hoặc đã cũ. Hãy chờ GPS trước khi xác định vị trí.',
      );
      return;
    }
    if (!_locatingAddress &&
        (_addressPosition == null ||
            _addressPosition!.distanceTo(progress.position!) > 50)) {
      _locatingAddress = true;
      final address = await _geocodingService.reverse(
        progress.currentLat,
        progress.currentLng,
      );
      _locatingAddress = false;
      if (_disposed) return;
      currentAddress = address;
      _addressPosition = progress.position;
    }
    final street = progress.streetName;
    final heading = progress.headingDegrees;
    await _ttsService.speak(
      '${currentAddress == null ? (street.isEmpty ? 'Vị trí của bạn' : 'Bạn đang gần $street') : 'Bạn đang gần $currentAddress'}: '
      'vĩ độ ${progress.currentLat.toStringAsFixed(5)}, kinh độ ${progress.currentLng.toStringAsFixed(5)}. '
      '${heading == null ? 'Chưa có hướng la bàn.' : 'Điện thoại đang hướng ${cardinalDirection(heading)}.'} '
      'Sai số GPS khoảng ${progress.accuracyMeters?.round() ?? 0} mét.',
    );
  }

  Future<bool> start() async {
    final epoch = _perceptionEpoch;
    if (_disposed ||
        _cameraBorrowed ||
        _navigationPaused ||
        _running ||
        !_frameSource.isReady) {
      return false;
    }
    final healthy = await _detectionService.isHealthy();
    if (_disposed ||
        _cameraBorrowed ||
        _navigationPaused ||
        _running ||
        epoch != _perceptionEpoch) {
      return false;
    }
    if (!healthy) {
      cameraError = 'Không kết nối được AI vật cản. Kiểm tra AI Server.';
      _stateController.add(
        const SessionRunning(statusText: 'Không thể kết nối AI Server.'),
      );
      return false;
    }
    _running = true;
    cameraError = null;
    _stateController.add(const SessionRunning(statusText: 'AI đang chạy'));
    _captureTimer = Timer.periodic(
      AiConfig.captureInterval,
      (_) => _captureAndDetect(),
    );
    unawaited(_captureAndDetect());
    return true;
  }

  void stop() {
    ++_perceptionEpoch;
    _captureTimer?.cancel();
    _captureTimer = null;
    _running = false;
    if (!_disposed) {
      _stateController.add(const SessionRunning(statusText: 'AI đã dừng'));
    }
  }

  Future<void> _captureAndDetect() async {
    if (!_running ||
        _cameraBorrowed ||
        _requestInProgress ||
        !_frameSource.isReady) {
      return;
    }
    _requestInProgress = true;
    final epoch = _perceptionEpoch;
    final cameraIdle = _cameraIdle = Completer<void>();
    final startedAt = DateTime.now();
    XFile? image;
    try {
      image = await _useCamera<XFile>(_frameSource.captureFrame);
      try {
        _latestJpeg = await image.readAsBytes();
        _jpegAt = DateTime.now();
      } catch (_) {
        // Assistant caching must never fail the existing YOLO pipeline.
        _latestJpeg = null;
        _jpegAt = null;
      }
      cameraIdle.complete();
      final result = await _detectionService.detect(image);
      if (_disposed || !_running || epoch != _perceptionEpoch) return;
      cameraError = null;
      _latestObjects = result.objects;
      _yoloAt = DateTime.now();
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
      await _processResult(result, epoch);
    } on CameraException {
      if (_running && epoch == _perceptionEpoch) {
        cameraError = 'Lỗi chụp ảnh từ camera.';
        _stateController.add(
          const SessionRunning(statusText: 'Lỗi chụp ảnh từ camera.'),
        );
      }
    } on AiDetectionException catch (error) {
      if (_running && epoch == _perceptionEpoch) {
        cameraError = error.message;
        _stateController.add(SessionRunning(statusText: error.message));
      }
    } catch (_) {
      if (!_disposed && _running && epoch == _perceptionEpoch) {
        cameraError = 'Nhận diện tạm thời không khả dụng. GPS vẫn hoạt động.';
        _stateController.add(SessionRunning(statusText: cameraError!));
      }
    } finally {
      if (!cameraIdle.isCompleted) cameraIdle.complete();
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

  Future<void> _processResult(DetectionResult result, int epoch) async {
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
          await _ttsService.speak('Chưa phát hiện vật cản phía trước.');
          _lastSpokenWarning = 'Chưa phát hiện vật cản phía trước.';
          _lastSpokenAt = DateTime.now();
          _lastSpokenDanger = null;
        }
      }
      return;
    }

    _emptyCycles = 0;
    _wasDangerous = true;
    _obstacleUntil = DateTime.now().add(const Duration(seconds: 5));
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
      if (_disposed || !_running || epoch != _perceptionEpoch || _isListening) {
        return;
      }
      if (await _ttsService.speak(warning.text, priority: 3)) {
        _lastSpokenWarning = warning.text;
        _lastSpokenAt = now;
        _lastSpokenDanger = warning.danger;
      }
    }
  }

  String _positionLabel(String position) => switch (position) {
    'left' => 'trái',
    'right' => 'phải',
    _ => 'giữa',
  };

  Future<void> onTalkStart() async {
    if (_disposed || _isListening) return;
    _isListening = true;
    _listeningController.add(true);
    try {
      _listeningStart = _beginListening();
      await _listeningStart;
    } on VoiceException catch (error) {
      _isListening = false;
      _listeningController.add(false);
      _stateController.add(SessionRunning(statusText: error.message));
      await _ttsService.speak(error.message);
    } finally {
      _listeningStart = null;
    }
  }

  Future<void> _beginListening() async {
    await _ttsService.silence();
    if (_disposed) return;
    await _voiceService.startListening(
      onResult: (text) {
        _stateController.add(SessionRunning(statusText: 'Đang nghe: $text'));
      },
    );
  }

  Future<void> onTalkEnd() async {
    if (_disposed) return;
    try {
      await _listeningStart;
    } on VoiceException {
      return;
    }
    if (_disposed) return;
    final text = await _voiceService.stopListening();
    if (_disposed) return;
    _isListening = false;
    _listeningController.add(false);
    if (text == null || text.trim().isEmpty) {
      _stateController.add(
        SessionRunning(statusText: _running ? 'AI đang chạy' : 'AI đã dừng'),
      );
      return;
    }

    await handleUtterance(text);
  }

  /// Shared by the primary microphone and typed conversation. Core templates
  /// never need OpenAI, and only this controller may execute navigation actions.
  Future<void> handleUtterance(String text, {bool includeImage = false}) async {
    if (_disposed || text.trim().isEmpty) return;
    final request = ++_destinationRequest;
    final command = VoiceCommand.parse(text);
    lastUtterance = text.trim();
    lastCommandKind = command.kind;
    _stateController.add(SessionRunning(statusText: routeSnapshot.message));
    if (command.kind != VoiceCommandKind.assistant &&
        command.kind != VoiceCommandKind.confirm &&
        command.kind != VoiceCommandKind.dismiss) {
      assistant.invalidate();
    }
    switch (command.kind) {
      case VoiceCommandKind.confirm:
        if (_pendingDestination != null) {
          await confirmPendingDestination();
        } else if (assistant.state.proposal != null) {
          await assistant.confirmProposal();
        } else {
          await _ttsService.speak('Chưa có thao tác đang chờ xác nhận.');
        }
        return;
      case VoiceCommandKind.dismiss:
        assistant.invalidate();
        cancelPendingDestination();
        await _ttsService.speak('Đã bỏ yêu cầu đang chờ xác nhận.');
        return;
      case VoiceCommandKind.location:
        await describeLocation();
        return;
      case VoiceCommandKind.cancelNavigation:
        cancelDestination();
        return;
      case VoiceCommandKind.repeat:
        await repeatInstruction();
        return;
      case VoiceCommandKind.refresh:
        await refreshRoute();
        return;
      case VoiceCommandKind.assistant:
        // Avoid two simultaneous confirmations for different destinations.
        _pendingDestination = null;
        await assistant.ask(
          text,
          includeImage: includeImage || command.includeImage,
        );
        return;
      case VoiceCommandKind.destination:
        _pendingDestination = null;
    }
    final destinationQuery = command.destination!;

    _stateController.add(
      SessionRunning(
        statusText: _running ? 'AI đang chạy' : 'AI đã dừng',
        subStatusText: 'Đang tìm đường đến $destinationQuery...',
      ),
    );
    try {
      final place = await findDestination(destinationQuery);
      if (_disposed || request != _destinationRequest) return;
      assistant.invalidate();
      _pendingDestination = place;
      final confirmation =
          'Địa điểm tìm được: ${place.displayName}. Nói “xác nhận” để dẫn đường, hoặc “hủy”.';
      _stateController.add(SessionRunning(statusText: confirmation));
      await _ttsService.speak(confirmation);
    } on GeocodingException catch (error) {
      if (_disposed || request != _destinationRequest) return;
      await _ttsService.speak(error.message);
      _stateController.add(
        SessionRunning(
          statusText: _running ? 'AI đang chạy' : 'AI đã dừng',
          subStatusText: error.message,
        ),
      );
    }
  }

  bool get isListening => _isListening;

  /// Temporarily lend the one camera to QR scanning, without stopping GPS or
  /// route guidance. Wait for capture, not for the network detection response.
  Future<bool> suspendCameraForQr() async {
    if (_disposed || _navigationPaused || _cameraBorrowed || _isListening) {
      throw const AssistantException('Hãy kết thúc ghi âm trước khi quét QR.');
    }
    final wasRunning = _running;
    _cameraBorrowed = true;
    assistant.invalidate();
    stop();
    try {
      await _cameraIdle?.future.timeout(const Duration(seconds: 10));
      await _useCamera(_frameSource.dispose);
      _latestJpeg = null;
      _jpegAt = null;
      if (_disposed) return wasRunning;
      _stateController.add(
        const SessionRunning(statusText: 'Đang quét QR ghép nối.'),
      );
      return wasRunning;
    } catch (_) {
      _cameraBorrowed = false;
      if (wasRunning) unawaited(start());
      throw const AssistantException('Camera đang bận. Hãy thử quét QR lại.');
    }
  }

  Future<void> resumeCameraAfterQr({required bool restartPerception}) async {
    if (!_cameraBorrowed || _disposed) return;
    _cameraBorrowed = false;
    if (_navigationPaused) return;
    await _openCamera();
    if (_disposed || _navigationPaused) return;
    _stateController.add(SessionRunning(statusText: routeSnapshot.message));
    if (restartPerception) await start();
  }

  Future<AssistantImage> _assistantImage() async {
    if (_cameraBorrowed) {
      throw const AssistantException('Camera đang được dùng để quét QR.');
    }
    if (_latestJpeg != null &&
        _jpegAt != null &&
        DateTime.now().difference(_jpegAt!) < const Duration(seconds: 5)) {
      return AssistantImage(_latestJpeg!, _jpegAt!);
    }
    if (_requestInProgress || !_frameSource.isReady) {
      throw const AssistantException('Camera chưa sẵn sàng để phân tích ảnh.');
    }
    _requestInProgress = true;
    final cameraIdle = _cameraIdle = Completer<void>();
    XFile? image;
    try {
      image = await _useCamera<XFile>(_frameSource.captureFrame);
      final bytes = await image.readAsBytes();
      final capturedAt = DateTime.now();
      _latestJpeg = bytes;
      _jpegAt = capturedAt;
      return AssistantImage(bytes, capturedAt);
    } finally {
      cameraIdle.complete();
      _requestInProgress = false;
      if (image != null) {
        try {
          await File(image.path).delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _performAssistantAction(AssistantProposal proposal) async {
    switch (proposal.action) {
      case 'set_destination':
        await navigateTo(proposal.place!);
      case 'refresh_route':
        await refreshRoute();
      case 'cancel_navigation':
        cancelDestination();
      case 'repeat_instruction':
        await repeatInstruction();
      case 'describe_location':
        await describeLocation();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    ++_destinationRequest;
    _routeSpeechTimer?.cancel();
    _captureTimer?.cancel();
    await assistant.dispose();
    await _routeSubscription?.cancel();
    await _routeService.dispose();
    await _useCamera(_frameSource.dispose);
    _detectionService.dispose();
    _voiceService.dispose();
    _geocodingService.dispose();
    await _ttsService.dispose();
    await _stateController.close();
    await _frameController.close();
    await _listeningController.close();
  }
}

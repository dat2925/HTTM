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
import '../services/situation_engine.dart';
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
  DateTime? _lastPerceptionFailureAt;
  Uint8List? _latestJpeg;
  DateTime? _jpegAt;
  final _situationEngine = SituationEngine();
  late final AssistantController assistant = AssistantController(
    service: _assistantService,
    situationEngine: _situationEngine,
    snapshot: () => routeSnapshot,
    detections: () => _latestObjects,
    yoloUpdatedAt: () => _yoloAt,
    captureImage: _assistantImage,
    onConfirmed: _performAssistantAction,
    speak: (text) => _speak(text, priority: 0),
    canSpeak: () =>
        !_disposed &&
        !_cameraBorrowed &&
        !_navigationPaused &&
        !_isListening &&
        (_obstacleUntil == null || DateTime.now().isAfter(_obstacleUntil!)) &&
        (_lastRouteSpokenAt == null ||
            DateTime.now().difference(_lastRouteSpokenAt!) >
                const Duration(seconds: 8)),
    canProactivelyRequest: () =>
        !_disposed &&
        !_cameraBorrowed &&
        !_navigationPaused &&
        !_isListening &&
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
  int _voiceEpoch = 0;
  int? _endingVoiceEpoch;
  bool _cameraBorrowed = false;
  Completer<void>? _cameraIdle;
  Future<void>? _cameraWork;
  Future<void>? _initialization, _pauseWork;
  Future<void>? _ttsInitialization;
  bool _ttsReady = false;
  int _speechEpoch = 0;
  String? ttsError;
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

  Future<T> _useCamera<T>(Future<T> Function() action) async {
    final previous = _cameraWork;
    final completed = Completer<void>();
    _cameraWork = completed.future;
    try {
      await previous;
      return await action();
    } finally {
      if (identical(_cameraWork, completed.future)) _cameraWork = null;
      completed.complete();
    }
  }

  Future<void> initialize() {
    if (_disposed) return Future.value();
    final core = _initialization ??= _initialize();
    return Future.wait<void>([core, _ensureTts()]).then<void>((_) {});
  }

  Future<void> _ensureTts() {
    if (_disposed || _ttsReady) return Future.value();
    return _ttsInitialization ??= _initializeTts().whenComplete(
      () => _ttsInitialization = null,
    );
  }

  Future<void> _initializeTts() async {
    try {
      await _ttsService.initialize().timeout(const Duration(seconds: 5));
      if (_disposed) return;
      _ttsReady = true;
      ttsError = null;
    } catch (_) {
      if (_disposed) return;
      _ttsReady = false;
      ttsError =
          'Chưa dùng được giọng đọc. Bản đồ, GPS và camera vẫn hoạt động.';
    }
    if (!_disposed) {
      _stateController.add(
        SessionRunning(statusText: ttsError ?? routeSnapshot.message),
      );
    }
  }

  Future<bool> _speak(String text, {int priority = 2}) async {
    if (_disposed) return false;
    final epoch = _speechEpoch;
    if (!_ttsReady && ttsError == null) await _ensureTts();
    if (_disposed || !_ttsReady || epoch != _speechEpoch) return false;
    try {
      return await _ttsService.speak(text, priority: priority);
    } catch (_) {
      return false;
    }
  }

  Future<void> _silence() async {
    ++_speechEpoch;
    try {
      await _ttsService.silence();
    } catch (_) {
      // Native audio failure must never prevent STT or lifecycle cleanup.
    }
  }

  Future<void> _initialize() async {
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
    final spoken = await _speak(instruction.text, priority: 1);
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
    await Future.wait<void>([
      if (!_cameraBorrowed) _openCamera(),
      _ensureTts(),
    ]);
  }

  Future<void> pauseNavigation() {
    ++_navigationLifecycle;
    if (_disposed) return Future.value();
    if (_navigationPaused) return _pauseWork ?? Future.value();
    assistant.invalidate();
    _navigationPaused = true;
    ++_destinationRequest;
    _invalidateVoice();
    stop();
    _routeService.stop();
    return _pauseWork = _pauseHardware();
  }

  Future<void> _pauseHardware() async {
    await _silence();
    await _finishVoice();
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
      await _speak(progress.message);
      return;
    }
    if (progress.updatedAt == null ||
        DateTime.now().difference(progress.updatedAt!) >
            AiConfig.gpsStaleAfter ||
        progress.status == NavigationStatus.poorGps) {
      await _speak(
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
    await _speak(
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
    _latestObjects = const [];
    _yoloAt = null;
    _latestJpeg = null;
    _jpegAt = null;
    _situationEngine.clearPerception();
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
      final capturedAt = DateTime.now();
      try {
        final jpeg = await image.readAsBytes();
        if (!_disposed && _running && epoch == _perceptionEpoch) {
          _latestJpeg = jpeg;
          _jpegAt = capturedAt;
        }
      } catch (_) {
        // Assistant caching must never fail the existing YOLO pipeline.
        _latestJpeg = null;
        _jpegAt = null;
      }
      cameraIdle.complete();
      final result = await _detectionService.detect(image);
      if (_disposed || !_running || epoch != _perceptionEpoch) return;
      if (!SituationEngine.fresh(
        capturedAt,
        DateTime.now(),
        SituationEngine.detectionTtl,
      )) {
        _latestObjects = const [];
        _yoloAt = null;
        _perceptionUnavailable();
        cameraError = 'Kết quả nhận diện đã cũ. Đang chờ khung hình mới.';
        _stateController.add(SessionRunning(statusText: cameraError!));
        return;
      }
      cameraError = null;
      _latestObjects = result.objects;
      _yoloAt = capturedAt;
      _situationEngine.observeDetections(
        result.objects,
        capturedAt,
        DateTime.now(),
      );
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
        _perceptionUnavailable();
        cameraError = 'Lỗi chụp ảnh từ camera.';
        _stateController.add(
          const SessionRunning(statusText: 'Lỗi chụp ảnh từ camera.'),
        );
      }
    } on AiDetectionException catch (error) {
      if (_running && epoch == _perceptionEpoch) {
        _perceptionUnavailable();
        cameraError = error.message;
        _stateController.add(SessionRunning(statusText: error.message));
      }
    } catch (_) {
      if (!_disposed && _running && epoch == _perceptionEpoch) {
        _perceptionUnavailable();
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
            statusText:
                'Camera chưa ghi nhận đối tượng; chưa xác định được lối đi.',
            subStatusText: routeText == null ? null : 'Route: $routeText',
          ),
        );
        if (shouldSpeakSafe) {
          await _speak(
            'Camera chưa ghi nhận đối tượng; chưa xác định được lối đi.',
          );
          _lastSpokenWarning =
              'Camera chưa ghi nhận đối tượng; chưa xác định được lối đi.';
          _lastSpokenAt = DateTime.now();
          _lastSpokenDanger = null;
        }
      }
      return;
    }

    _emptyCycles = 0;
    _wasDangerous = true;
    final decisionSource = routeText == null
        ? 'Camera: đối tượng ở ${_positionLabel(warning.object.position)} khung hình'
        : 'Route: $routeText · Camera: đối tượng ở ${_positionLabel(warning.object.position)} khung hình';
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
      try {
        if (warning.danger == DangerLevel.high) {
          await HapticFeedback.heavyImpact();
        } else if (warning.danger == DangerLevel.medium) {
          await HapticFeedback.mediumImpact();
        }
      } catch (_) {
        /* Missing haptics must not block the local spoken warning. */
      }
      if (_disposed || !_running || epoch != _perceptionEpoch || _isListening) {
        return;
      }
      if (await _speak(warning.text, priority: 3)) {
        _obstacleUntil = DateTime.now().add(const Duration(seconds: 5));
        _lastSpokenWarning = warning.text;
        _lastSpokenAt = now;
        _lastSpokenDanger = warning.danger;
      }
    }
  }

  void _perceptionUnavailable() {
    _latestObjects = const [];
    _yoloAt = null;
    _situationEngine.sensorUnavailable(DateTime.now());
    final now = DateTime.now();
    if (!_isListening &&
        (_lastPerceptionFailureAt == null ||
            now.difference(_lastPerceptionFailureAt!) >=
                const Duration(seconds: 30))) {
      _lastPerceptionFailureAt = now;
      unawaited(
        _speak(
          'Chưa có nhận diện camera mới. Cảnh báo vật cản đang thiếu dữ liệu.',
          priority: 2,
        ),
      );
    }
  }

  String _positionLabel(String position) => switch (position) {
    'left' => 'trái',
    'right' => 'phải',
    _ => 'giữa',
  };

  Future<void> onTalkStart() async {
    if (_disposed || _navigationPaused || _isListening) return;
    final epoch = ++_voiceEpoch;
    _isListening = true;
    _listeningController.add(true);
    final starting = _listeningStart = _beginListening(epoch);
    try {
      await starting;
    } catch (error) {
      if (!_voiceCurrent(epoch)) return;
      _isListening = false;
      _listeningController.add(false);
      await _cancelRecognition();
      if (!_voiceCurrent(epoch)) return;
      final message = error is VoiceException
          ? error.message
          : 'Không thể dùng micro. Hãy kiểm tra quyền và dịch vụ nhận dạng giọng nói.';
      _stateController.add(SessionRunning(statusText: message));
      try {
        await _speak(message);
      } catch (_) {
        // The visible microphone error remains usable without native TTS.
      }
    } finally {
      if (identical(_listeningStart, starting)) _listeningStart = null;
    }
  }

  bool _voiceCurrent(int epoch) =>
      !_disposed && !_navigationPaused && epoch == _voiceEpoch;

  void _invalidateVoice() {
    ++_voiceEpoch;
    _endingVoiceEpoch = null;
    _isListening = false;
    if (!_disposed) _listeningController.add(false);
  }

  Future<void> _cancelRecognition() async {
    try {
      await _voiceService.cancelListening();
    } catch (_) {
      // A native cancellation failure must not block camera/GPS cleanup.
    }
  }

  Future<void> _finishVoice() async {
    try {
      await _listeningStart;
    } catch (_) {
      // Startup may have failed; still cancel any partially opened recognizer.
    }
    await _cancelRecognition();
  }

  Future<void> _beginListening(int epoch) async {
    await _silence();
    if (!_voiceCurrent(epoch)) return;
    await _voiceService.startListening(
      onResult: (text) {
        if (_voiceCurrent(epoch) && _isListening) {
          _stateController.add(SessionRunning(statusText: 'Đang nghe: $text'));
        }
      },
    );
  }

  Future<void> onTalkEnd() async {
    final epoch = _voiceEpoch;
    if (!_voiceCurrent(epoch) || !_isListening || _endingVoiceEpoch == epoch) {
      return;
    }
    _endingVoiceEpoch = epoch;
    try {
      await _listeningStart;
      if (!_voiceCurrent(epoch) || !_isListening) return;
      final text = await _voiceService.stopListening();
      if (!_voiceCurrent(epoch)) return;
      _isListening = false;
      _listeningController.add(false);
      // A new press may interrupt a slow AI/geocoding response after STT ends.
      _endingVoiceEpoch = null;
      if (text == null || text.trim().isEmpty) {
        _stateController.add(
          SessionRunning(statusText: _running ? 'AI đang chạy' : 'AI đã dừng'),
        );
        return;
      }
      await handleUtterance(text);
    } catch (_) {
      if (_voiceCurrent(epoch)) {
        await _cancelRecognition();
        if (!_voiceCurrent(epoch)) return;
        _stateController.add(
          const SessionRunning(
            statusText: 'Không nhận được giọng nói. Hãy thử lại.',
          ),
        );
      }
    } finally {
      if (_voiceCurrent(epoch) && _isListening) {
        _isListening = false;
        _listeningController.add(false);
      }
      if (_endingVoiceEpoch == epoch) _endingVoiceEpoch = null;
    }
  }

  /// Shared by the primary microphone and typed conversation. Core templates
  /// never need OpenAI, and only this controller may execute navigation actions.
  Future<void> handleUtterance(String text, {bool includeImage = false}) async {
    if (_disposed || _navigationPaused || text.trim().isEmpty) return;
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
      case VoiceCommandKind.monitor:
        _situationEngine.watch(command.monitorCategory, DateTime.now());
        final message = _assistantService.proactiveEnabled
            ? 'Theo dõi nhóm đối tượng ở giữa khung hình trong hai phút khi camera nhận diện đang chạy. Tôi chưa theo dõi được từng đối tượng riêng.'
            : 'Đã ghi nhận yêu cầu hai phút. Hãy bật Thông tin chủ động và nhận diện camera để nhận thông báo theo dõi.';
        _stateController.add(SessionRunning(statusText: message));
        await _speak(message);
        return;
      case VoiceCommandKind.stopMonitoring:
        _situationEngine.watch(null, DateTime.now());
        await _speak('Đã dừng theo dõi theo yêu cầu.');
        return;
      case VoiceCommandKind.confirm:
        if (_pendingDestination != null) {
          await confirmPendingDestination();
        } else if (assistant.state.proposal != null) {
          await assistant.confirmProposal();
        } else {
          await _speak('Chưa có thao tác đang chờ xác nhận.');
        }
        return;
      case VoiceCommandKind.dismiss:
        assistant.invalidate();
        cancelPendingDestination();
        await _speak('Đã bỏ yêu cầu đang chờ xác nhận.');
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
      if (_disposed || _navigationPaused || request != _destinationRequest) {
        return;
      }
      assistant.invalidate();
      _pendingDestination = place;
      final confirmation =
          'Địa điểm tìm được: ${place.displayName}. Nói “xác nhận” để dẫn đường, hoặc “hủy”.';
      _stateController.add(SessionRunning(statusText: confirmation));
      await _speak(confirmation);
    } on GeocodingException catch (error) {
      if (_disposed || _navigationPaused || request != _destinationRequest) {
        return;
      }
      await _speak(error.message);
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
      final capturedAt = DateTime.now();
      final bytes = await image.readAsBytes();
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
    _invalidateVoice();
    stop();
    ++_destinationRequest;
    _routeSpeechTimer?.cancel();
    _captureTimer?.cancel();
    await assistant.dispose();
    await _routeSubscription?.cancel();
    await _routeService.dispose();
    await _finishVoice();
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

import 'dart:async';
import 'dart:typed_data';
import '../models/assistant_state.dart';
import '../models/detection_result.dart';
import '../models/route_progress.dart';
import '../models/situation_context.dart';
import '../services/assistant_service.dart';
import '../services/assistant_policy.dart';
import '../services/situation_engine.dart';

class AssistantImage {
  const AssistantImage(this.bytes, this.capturedAt);
  final Uint8List bytes;
  final DateTime capturedAt;
}

class AssistantController {
  AssistantController({
    required this.service,
    required this.snapshot,
    required this.detections,
    required this.yoloUpdatedAt,
    required this.captureImage,
    required this.onConfirmed,
    required this.speak,
    required this.canSpeak,
    required this.canProactivelyRequest,
    SituationEngine? situationEngine,
  }) : _situationEngine = situationEngine ?? SituationEngine();
  final SituationEngine _situationEngine;
  final AiAssistantService service;
  final RouteProgress Function() snapshot;
  final List<DetectedObject> Function() detections;
  final DateTime? Function() yoloUpdatedAt;
  final Future<AssistantImage> Function() captureImage;
  final Future<void> Function(AssistantProposal) onConfirmed;
  final Future<bool> Function(String) speak;
  final bool Function() canSpeak;
  final bool Function() canProactivelyRequest;
  final _states = StreamController<AssistantState>.broadcast();
  final _policy = AssistantProactivityPolicy();
  final List<AssistantMessage> _messages = [];
  AssistantState _state = const AssistantState();
  AssistantProposal? _proposal;
  RouteProgress? _requestContext;
  DateTime? _requestedAt;
  String? _error, _pendingSpeech;
  String? _precautionSpeech, _requestSceneKey;
  DateTime? _precautionExpires;
  DateTime? _speechExpires;
  DateTime? _lastInteraction;
  Timer? _timer;
  bool _busy = false, _disposed = false;
  bool _activeProactive = false, _deliveringSpeech = false;
  bool _requiresLiveContext = true;
  int _epoch = 0;
  NavigationStatus? _observedStatus;
  DateTime? _statusSince;
  int? _requestedRevision;
  DateTime? _evidenceExpires;
  Stream<AssistantState> get states => _states.stream;
  AssistantState get state => _state;

  Future<void> initialize() async {
    await service.initialize();
    if (_disposed) return;
    _publish();
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_tick()),
    );
  }

  Future<bool> pair(String code, {bool allowInsecure = false}) async {
    if (_disposed) return false;
    invalidate();
    final epoch = _epoch;
    try {
      await service.pair(code, allowInsecure: allowInsecure);
      if (_disposed || epoch != _epoch) return false;
      _error = null;
    } on AssistantException catch (error) {
      if (_disposed || epoch != _epoch) return false;
      _error = error.message;
    } catch (_) {
      if (_disposed || epoch != _epoch) return false;
      _error = 'Không lưu được thông tin ghép nối trên thiết bị.';
    }
    _publish();
    return _error == null && service.paired;
  }

  Future<void> unpair() async {
    invalidate();
    try {
      final unpairing = service.unpair();
      _publish(); // Local token removal is immediate, even if revocation is slow.
      await unpairing;
      _error = null;
    } catch (_) {
      _error = 'Đã xóa token trên thiết bị; chưa xác minh thu hồi ở server.';
    }
    _messages.clear();
    _publish();
  }

  Future<void> setProactive(bool enabled) async {
    if (!enabled && _activeProactive) invalidate();
    try {
      await service.setProactive(enabled);
      _error = null;
    } catch (_) {
      _error = 'Không lưu được tùy chọn trợ lý.';
    }
    _publish();
  }

  Future<void> reset() async {
    invalidate();
    _messages.clear();
    try {
      await service.reset();
      _error = null;
    } catch (_) {
      _error =
          'Đã bắt đầu hội thoại mới trên thiết bị; chưa xóa được hội thoại ở server.';
    }
    _publish();
  }

  void observe(RouteProgress progress) {
    _situation();
    if (_observedStatus != progress.status) {
      _observedStatus = progress.status;
      _statusSince = DateTime.now();
    }
    if (_proposal != null && !_contextValid()) {
      _proposal = null;
      _publish();
    }
  }

  bool _contextValid() =>
      _requestContext != null &&
      _requestedAt != null &&
      snapshot().status != NavigationStatus.paused &&
      DateTime.now().difference(_requestedAt!) <= const Duration(seconds: 30) &&
      (!_requiresLiveContext ||
          ((_requestedRevision == null ||
                  _requestedRevision == _situation().revision) &&
              AssistantProactivityPolicy.contextStillCurrent(
                _requestContext!,
                snapshot(),
                _requestedAt!,
                DateTime.now(),
              ))) &&
      (_evidenceExpires == null || DateTime.now().isBefore(_evidenceExpires!));

  // Same engine is shared with SessionController; legacy callbacks remain useful
  // for callers/tests and never mark a network response as a fresh capture.
  SituationContext _situation({DateTime? imageAt}) {
    final now = DateTime.now(), at = yoloUpdatedAt();
    if (at != null &&
        SituationEngine.fresh(at, now, SituationEngine.detectionTtl)) {
      _situationEngine.observeDetections(detections(), at, now);
    } else {
      _situationEngine.clearPerception();
    }
    return _situationEngine.snapshot(snapshot(), now, imageAt: imageAt);
  }

  Future<void> ask(
    String message, {
    bool includeImage = false,
    bool proactive = false,
    String? event,
  }) async {
    if (_disposed || message.trim().isEmpty) return;
    if (proactive &&
        (_busy || !service.proactiveEnabled || !canProactivelyRequest())) {
      return;
    }
    invalidate();
    _activeProactive = proactive;
    final epoch = _epoch;
    if (!service.paired) {
      _error =
          'Hãy ghép nối trợ lý trong mục Trợ lý AI. Dẫn đường vẫn hoạt động.';
      _queueErrorSpeech();
      _publish();
      await _deliverSpeech();
      return;
    }
    _busy = true;
    _error = null;
    if (!proactive) {
      _lastInteraction = DateTime.now();
      _messages.add(AssistantMessage(message.trim(), fromUser: true));
    }
    _publish();
    try {
      AssistantImage? image;
      String? imageError;
      if (includeImage) {
        try {
          image = await captureImage();
        } on AssistantException catch (error) {
          imageError = error.message;
        } catch (_) {
          imageError = 'Camera chưa sẵn sàng.';
        }
        if (image != null &&
            !SituationEngine.fresh(
              image.capturedAt,
              DateTime.now(),
              SituationEngine.imageTtl,
            )) {
          image = null;
          imageError = 'Ảnh camera đã cũ.';
        }
      }
      if (_disposed || epoch != _epoch) return;
      final captured = snapshot(), requestedAt = DateTime.now();
      _requestContext = captured;
      _requestedAt = requestedAt;
      final situation = _situation(imageAt: image?.capturedAt);
      _requestedRevision = situation.revision;
      _requestSceneKey = situation.sceneKey;
      _evidenceExpires = image?.capturedAt.add(SituationEngine.imageTtl);
      final reply = await service.chat(
        imageError == null
            ? message.trim()
            : '${message.trim()}\nCamera không khả dụng; hãy dùng nguồn khác và nêu giới hạn.',
        situation.toNavigationJson(),
        image: image?.bytes,
        proactive: proactive,
        event: event,
      );
      if (_disposed || epoch != _epoch) return;
      _evidenceExpires = reply.expiresAt;
      if (reply.guidance != null &&
          !reply.guidance!.evidenceSources.any((s) => s != 'user') &&
          reply.proposals.isEmpty) {
        _requestedRevision = null;
        _requiresLiveContext = false;
      }
      if (!_contextValid()) {
        _error = proactive
            ? null
            : 'Vị trí hoặc tuyến đã thay đổi. Hãy hỏi lại để nhận thông tin mới.';
        return;
      }
      _messages.add(
        AssistantMessage(
          reply.text,
          proactive: proactive,
          guidance: reply.guidance,
          observedAt: requestedAt,
        ),
      );
      _proposal = !proactive && reply.proposals.isNotEmpty
          ? reply.proposals.first
          : null;
      _pendingSpeech = reply.speechText ?? reply.text;
      _speechExpires = reply.expiresAt;
      final recommendations =
          reply.guidance?.recommendations ?? const <String>[];
      if (recommendations.isNotEmpty) {
        _precautionSpeech =
            'Nếu tình huống này vẫn còn: ${recommendations.take(2).join(' ')}';
        _precautionExpires = reply.guidance?.precautionExpiresAt;
      }
      await _deliverSpeech();
    } on AssistantException catch (error) {
      if (epoch == _epoch) _error = proactive ? null : error.message;
    } catch (_) {
      if (epoch == _epoch) {
        _error = proactive
            ? null
            : 'Trợ lý tạm thời không khả dụng. Dẫn đường vẫn hoạt động.';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        _busy = false;
        if (!proactive && _error != null) {
          _queueErrorSpeech();
          await _deliverSpeech();
        }
        _publish();
      }
    }
  }

  void _queueErrorSpeech() {
    _requiresLiveContext = false;
    _requestedRevision = null;
    _evidenceExpires = null;
    _requestContext = snapshot();
    _requestedAt = DateTime.now();
    _pendingSpeech = _error;
    _speechExpires = DateTime.now().add(const Duration(seconds: 15));
  }

  Future<void> _deliverSpeech() async {
    var text = _pendingSpeech;
    if ((text == null && _precautionSpeech == null) || _deliveringSpeech) {
      return;
    }
    if (text == null ||
        _speechExpires == null ||
        DateTime.now().isAfter(_speechExpires!) ||
        !_contextValid()) {
      _pendingSpeech = null;
      // Only server-rendered precaution actions outlive visual observations.
      // No expired observation is read as a current fact after an audio warning.
      if (_precautionExpires == null ||
          !DateTime.now().isBefore(_precautionExpires!) ||
          _requestContext == null ||
          _requestedAt == null ||
          snapshot().status == NavigationStatus.paused ||
          DateTime.now().difference(_requestedAt!) >
              const Duration(seconds: 30) ||
          (_requiresLiveContext &&
              (_requestSceneKey != _situation().sceneKey ||
                  !AssistantProactivityPolicy.contextStillCurrent(
                    _requestContext!,
                    snapshot(),
                    _requestedAt!,
                    DateTime.now(),
                  )))) {
        _precautionSpeech = null;
        return;
      }
      text = _precautionSpeech;
    }
    if (text == null) return;
    try {
      _deliveringSpeech = true;
      final epoch = _epoch;
      if (canSpeak() && await speak(text) && epoch == _epoch) {
        _pendingSpeech = null;
        _precautionSpeech = null;
      }
    } catch (_) {
      // Native TTS failure must not escape the assistant's optional timer.
      _pendingSpeech = null;
      _precautionSpeech = null;
    } finally {
      _deliveringSpeech = false;
    }
  }

  Future<void> _tick() => checkProactive();

  /// Called by a bounded local timer. Never called for every camera frame.
  Future<void> checkProactive() async {
    if (_disposed) return;
    final situation = _situation();
    await _deliverSpeech();
    if (_busy ||
        !service.paired ||
        !service.proactiveEnabled ||
        !canProactivelyRequest() ||
        (_lastInteraction != null &&
            DateTime.now().difference(_lastInteraction!) <
                const Duration(seconds: 120) &&
            !situation.events.any((e) => e.kind == 'watchMatch'))) {
      return;
    }
    final p = snapshot();
    final now = DateTime.now();
    final situationEvent = _policy.candidateSituation(situation, now);
    final event =
        situationEvent?.kind ??
        (_statusSince != null &&
                now.difference(_statusSince!) >= const Duration(seconds: 10)
            ? _policy.candidate(p, now)
            : null);
    if (event != null) {
      await ask(
        'Giải thích ngắn ngữ cảnh đáng chú ý này, tránh nhắc lại chỉ dẫn hoặc cảnh báo đã phát.',
        proactive: true,
        event: event,
      );
    }
  }

  Future<void> confirmProposal() async {
    final proposal = _proposal;
    if (proposal == null ||
        !_contextValid() ||
        DateTime.now().isAfter(proposal.expiresAt)) {
      _proposal = null;
      _error = 'Đề xuất đã cũ. Hãy hỏi lại trước khi xác nhận.';
      _publish();
      return;
    }
    _proposal = null;
    _pendingSpeech = null;
    _precautionSpeech = null;
    _publish();
    try {
      await onConfirmed(proposal);
    } catch (_) {
      _error =
          'Chưa thực hiện được thao tác dẫn đường. Hãy kiểm tra trạng thái hiện tại.';
      _publish();
    }
  }

  void dismissProposal() {
    _proposal = null;
    _publish();
  }

  void invalidate() {
    ++_epoch;
    service.cancel();
    _activeProactive = false;
    _requiresLiveContext = true;
    _requestedRevision = null;
    _evidenceExpires = null;
    _proposal = null;
    _pendingSpeech = null;
    _precautionSpeech = null;
    _precautionExpires = null;
    _requestSceneKey = null;
    _busy = false;
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    if (_messages.length > 30) _messages.removeRange(0, _messages.length - 30);
    _state = AssistantState(
      paired: service.paired,
      proactive: service.proactiveEnabled,
      busy: _busy,
      error: _error,
      messages: List.unmodifiable(_messages),
      proposal: _proposal,
    );
    _states.add(_state);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_epoch;
    _timer?.cancel();
    service.dispose();
    await _states.close();
  }
}

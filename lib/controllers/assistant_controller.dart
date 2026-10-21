import 'dart:async';
import 'dart:typed_data';
import '../models/assistant_state.dart';
import '../models/detection_result.dart';
import '../models/route_progress.dart';
import '../services/assistant_service.dart';
import '../services/assistant_policy.dart';

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
  });
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
  DateTime? _speechExpires;
  DateTime? _lastInteraction;
  Timer? _timer;
  bool _busy = false, _disposed = false;
  int _epoch = 0;
  NavigationStatus? _observedStatus;
  DateTime? _statusSince;
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
    try {
      await service.pair(code, allowInsecure: allowInsecure);
      _error = null;
    } on AssistantException catch (error) {
      _error = error.message;
    } catch (_) {
      _error = 'Không lưu được thông tin ghép nối trên thiết bị.';
    }
    _publish();
    return _error == null && service.paired;
  }

  Future<void> unpair() async {
    invalidate();
    try {
      await service.unpair();
      _error = null;
    } catch (_) {
      _error = 'Đã xóa token trên thiết bị; chưa xác minh thu hồi ở server.';
    }
    _messages.clear();
    _publish();
  }

  Future<void> setProactive(bool enabled) async {
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
      AssistantProactivityPolicy.contextStillCurrent(
        _requestContext!,
        snapshot(),
        _requestedAt!,
        DateTime.now(),
      );

  Map<String, dynamic> _context(
    RouteProgress p,
    DateTime now,
    DateTime? imageAt,
  ) {
    final yoloAt = yoloUpdatedAt();
    final freshYolo =
        yoloAt != null && now.difference(yoloAt) < const Duration(seconds: 5);
    return {
      'captured_at': now.toUtc().toIso8601String(),
      'position': p.position == null
          ? null
          : {'lat': p.position!.lat, 'lng': p.position!.lng},
      'gps_updated_at': p.updatedAt?.toUtc().toIso8601String(),
      'accuracy_meters': p.accuracyMeters,
      'heading_degrees': p.headingDegrees,
      'target_bearing': p.targetBearing,
      'status': p.status.name,
      'route_message': p.message,
      'street_name': p.streetName,
      'destination': p.destination == null
          ? null
          : {'lat': p.destination!.lat, 'lng': p.destination!.lng},
      'destination_name': p.destinationName,
      'remaining_meters': p.remainingMeters,
      'walked_meters': p.walkedMeters,
      'next_instructions': p.waypoints
          .skip(p.currentIndex)
          .take(8)
          .map((w) => w.instruction)
          .toList(),
      'obstacles': freshYolo
          ? detections()
                .take(20)
                .map(
                  (o) => {
                    'class_name': o.className,
                    'position': o.position,
                    'danger': o.danger.name,
                    'confidence': o.confidence,
                  },
                )
                .toList()
          : [],
      'yolo_updated_at': freshYolo ? yoloAt.toUtc().toIso8601String() : null,
      'image_captured_at': imageAt?.toUtc().toIso8601String(),
    };
  }

  Future<void> ask(
    String message, {
    bool includeImage = false,
    bool proactive = false,
    String? event,
  }) async {
    if (_disposed || message.trim().isEmpty) return;
    if (proactive && (_busy || !canProactivelyRequest())) return;
    invalidate();
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
      final image = includeImage ? await captureImage() : null;
      if (_disposed || epoch != _epoch) return;
      final captured = snapshot(), requestedAt = DateTime.now();
      _requestContext = captured;
      _requestedAt = requestedAt;
      final reply = await service.chat(
        message.trim(),
        _context(captured, requestedAt, image?.capturedAt),
        image: image?.bytes,
        proactive: proactive,
        event: event,
      );
      if (_disposed || epoch != _epoch) return;
      if (!_contextValid()) {
        _error = proactive
            ? null
            : 'Vị trí hoặc tuyến đã thay đổi. Hãy hỏi lại để nhận thông tin mới.';
        return;
      }
      _messages.add(AssistantMessage(reply.text, proactive: proactive));
      _proposal = !proactive && reply.proposals.isNotEmpty
          ? reply.proposals.first
          : null;
      _pendingSpeech = reply.text;
      _speechExpires = reply.expiresAt;
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
    _requestContext = snapshot();
    _requestedAt = DateTime.now();
    _pendingSpeech = _error;
    _speechExpires = DateTime.now().add(const Duration(seconds: 15));
  }

  Future<void> _deliverSpeech() async {
    final text = _pendingSpeech;
    if (text == null) return;
    if (_speechExpires == null ||
        DateTime.now().isAfter(_speechExpires!) ||
        !_contextValid()) {
      _pendingSpeech = null;
      return;
    }
    try {
      if (canSpeak() && await speak(text)) _pendingSpeech = null;
    } catch (_) {
      // Native TTS failure must not escape the assistant's optional timer.
      _pendingSpeech = null;
    }
  }

  Future<void> _tick() async {
    if (_disposed) return;
    await _deliverSpeech();
    if (_busy ||
        !service.paired ||
        !service.proactiveEnabled ||
        !canProactivelyRequest() ||
        (_lastInteraction != null &&
            DateTime.now().difference(_lastInteraction!) <
                const Duration(seconds: 120)) ||
        _statusSince == null ||
        DateTime.now().difference(_statusSince!) <
            const Duration(seconds: 10)) {
      return;
    }
    final p = snapshot();
    final event = _policy.candidate(p, DateTime.now());
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
    _proposal = null;
    _pendingSpeech = null;
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

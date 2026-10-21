import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/models/placemark.dart';
import 'package:smart_navigation/models/route_progress.dart';
import 'package:smart_navigation/services/frame_source.dart';
import 'package:smart_navigation/services/geocoding_service.dart';
import 'package:smart_navigation/services/route_service.dart';
import 'package:smart_navigation/services/tts_service.dart';
import 'package:smart_navigation/services/voice_service.dart';
import 'package:smart_navigation/models/assistant_state.dart';
import 'package:smart_navigation/services/voice_command_router.dart';
import 'assistant_test.dart' show FakeAssistant;

class NoCamera extends FrameSource {
  @override
  Future<void> initialize() async {
    throw CameraException('noCamera', 'No camera');
  }
}

class RecordingTts extends TtsService {
  final spoken = <String>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> speak(String text, {int priority = 2}) async {
    spoken.add(text);
    return true;
  }

  @override
  Future<void> silence() async {}
  @override
  Future<void> dispose() async {}
}

class FakeVoice extends VoiceService {
  String? text;
  @override
  Future<void> startListening({void Function(String)? onResult}) async {}
  @override
  Future<String?> stopListening() async => text;
  @override
  void dispose() {}
}

class FakeGeocoding extends GeocodingService {
  @override
  Future<Placemark> search(
    String query, {
    double? nearLat,
    double? nearLng,
  }) async => const Placemark(
    lat: 21,
    lng: 105,
    displayName: 'Địa chỉ đầy đủ được tìm',
  );
}

class FakeRoute extends RouteService {
  final events = StreamController<RouteInstruction>.broadcast(sync: true);
  int started = 0, destinations = 0, refreshes = 0, canceled = 0, stopped = 0;
  @override
  Stream<RouteInstruction> get instructions => events.stream;
  @override
  Stream<RouteProgress> get progress => const Stream.empty();
  @override
  RouteProgress get snapshot =>
      const RouteProgress(status: NavigationStatus.navigating);
  @override
  Future<void> start() async {
    started++;
  }

  @override
  void stop() {
    stopped++;
  }

  @override
  Future<bool> setDestination(double lat, double lng, {String? name}) async {
    destinations++;
    return true;
  }

  @override
  Future<void> refresh() async {
    refreshes++;
  }

  @override
  void cancelDestination() {
    canceled++;
  }

  @override
  Future<void> clearJourney() async {}
  @override
  Future<void> dispose() async {
    await events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'main STT keeps known commands local even when assistant unpaired',
    () async {
      final route = FakeRoute(),
          voice = FakeVoice(),
          ai = FakeAssistant()..enabled = false;
      final session = SessionController(
        routeService: route,
        voiceService: voice,
        ttsService: RecordingTts(),
        geocodingService: FakeGeocoding(),
        frameSource: NoCamera(),
        assistantService: ai,
      );
      for (final text in [
        'Tôi đang ở đâu?',
        'nhắc lại',
        'cập nhật tuyến',
        'dừng dẫn đường',
        'đi đến công viên',
        'xác nhận',
      ]) {
        voice.text = text;
        await session.onTalkEnd();
      }
      expect(ai.calls, 0);
      expect(route.refreshes, 1);
      expect(route.canceled, 1);
      expect(route.destinations, 1);
      expect(session.lastCommandKind, VoiceCommandKind.confirm);
      await session.dispose();
    },
  );
  test(
    'main STT and typed input share AI fallback and explicit confirmation',
    () async {
      final route = FakeRoute(), voice = FakeVoice(), ai = FakeAssistant();
      ai.reply = AssistantReply(
        requestId: 'test',
        text: 'Đề xuất công viên.',
        expiresAt: DateTime.now().add(const Duration(seconds: 15)),
        proposals: [
          AssistantProposal(
            id: 'test',
            action: 'set_destination',
            expiresAt: DateTime.now().add(const Duration(seconds: 45)),
            place: const Placemark(lat: 21, lng: 105, displayName: 'Công viên'),
          ),
        ],
      );
      final session = SessionController(
        routeService: route,
        voiceService: voice,
        ttsService: RecordingTts(),
        frameSource: NoCamera(),
        assistantService: ai,
      );
      voice.text = 'Gợi ý một nơi gần đây để đi dạo';
      await session.onTalkEnd();
      expect(ai.calls, 1);
      expect(session.lastCommandKind, VoiceCommandKind.assistant);
      expect(session.assistant.state.proposal, isNotNull);
      expect(route.destinations, 0);
      // Typed confirmation uses exactly the same controller as the microphone.
      await session.handleUtterance('xác nhận');
      expect(route.destinations, 1);
      expect(ai.calls, 1);
      await session.handleUtterance('Giải thích GPS giúp tôi');
      expect(ai.calls, 2);
      await session.dispose();
    },
  );
  test('local command cancels an AI response already in flight', () async {
    final ai = FakeAssistant()..pending = Completer<AssistantReply>();
    final session = SessionController(
      routeService: FakeRoute(),
      ttsService: RecordingTts(),
      frameSource: NoCamera(),
      assistantService: ai,
    );
    final pending = session.handleUtterance('Giải thích hành trình');
    await Future<void>.delayed(Duration.zero);
    await session.handleUtterance('dừng dẫn đường');
    ai.pending!.complete(
      AssistantReply(
        requestId: 'old',
        text: 'Phản hồi đã cũ',
        expiresAt: DateTime.now().add(const Duration(seconds: 15)),
      ),
    );
    await pending;
    expect(session.assistant.state.messages.where((m) => !m.fromUser), isEmpty);
    expect(session.assistant.state.proposal, isNull);
    await session.dispose();
  });
  test(
    'camera failure does not prevent GPS startup or spoken route instruction',
    () async {
      final route = FakeRoute(), tts = RecordingTts();
      final session = SessionController(
        routeService: route,
        ttsService: tts,
        frameSource: NoCamera(),
      );
      await session.initialize();
      route.events.add(
        const RouteInstruction(text: 'Sau 20 mét rẽ trái', key: 'left'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(route.started, 1);
      expect(session.cameraError, isNotNull);
      expect(tts.spoken, contains('Sau 20 mét rẽ trái'));
      await session.dispose();
    },
  );
  test('spoken destination waits for explicit address confirmation', () async {
    final route = FakeRoute(), tts = RecordingTts(), voice = FakeVoice();
    final session = SessionController(
      routeService: route,
      ttsService: tts,
      voiceService: voice,
      geocodingService: FakeGeocoding(),
      frameSource: NoCamera(),
    );
    await session.initialize();
    voice.text = 'đi đến công viên';
    await session.onTalkEnd();
    expect(route.destinations, 0);
    expect(session.pendingDestination?.displayName, 'Địa chỉ đầy đủ được tìm');
    expect(tts.spoken.last, contains('xác nhận'));
    voice.text = 'xác nhận';
    await session.onTalkEnd();
    expect(route.destinations, 1);
    expect(session.pendingDestination, isNull);
    await session.dispose();
  });
}

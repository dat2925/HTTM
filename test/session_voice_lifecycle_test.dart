import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/widgets/talk_button.dart';

import 'assistant_test.dart' show FakeAssistant;
import 'session_navigation_test.dart' show FakeRoute;
import 'support/device_fakes.dart';

class CallbackVoice extends FakeVoice {
  final callbacks = <void Function(String)>[];
  bool nativeStartError = false, nativeStopError = false;

  @override
  Future<void> startListening({void Function(String)? onResult}) async {
    if (onResult != null) callbacks.add(onResult);
    if (nativeStartError) {
      throw PlatformException(code: 'recognizerNotAvailable');
    }
    await super.startListening(onResult: onResult);
  }

  @override
  Future<String?> stopListening() async {
    if (nativeStopError) throw PlatformException(code: 'stopFailed');
    return super.stopListening();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CallbackVoice voice;
  late FakeRoute route;
  late SessionController session;
  setUp(() {
    voice = CallbackVoice();
    route = FakeRoute();
    session = SessionController(
      frameSource: FakeCamera(),
      routeService: route,
      voiceService: voice,
      ttsService: RecordingTts(),
      assistantService: FakeAssistant(),
    );
  });
  tearDown(() => session.dispose());

  test('late recognition callback cannot write to closed streams', () async {
    await session.onTalkStart();
    await session.dispose();
    expect(() => voice.callbacks.single('late transcript'), returnsNormally);
    expect(voice.cancels, 1);
  });

  test(
    'pause cancels native recognition and rejects its final command',
    () async {
      voice.stopGate = Completer<String?>();
      await session.onTalkStart();
      final ending = session.onTalkEnd();
      await flushDeviceEvents();
      await session.pauseNavigation();
      expect(session.isListening, isFalse);
      expect(voice.cancels, 1);
      voice.stopGate!.complete('dừng dẫn đường');
      await ending;
      expect(route.canceled, 0);
    },
  );

  test('duplicate releases execute exactly one local command', () async {
    voice.text = 'cập nhật tuyến';
    await session.onTalkStart();
    await Future.wait([session.onTalkEnd(), session.onTalkEnd()]);
    await session.onTalkEnd();
    expect(voice.stops, 1);
    expect(route.refreshes, 1);
  });

  test('native startup error resets listening and permits retry', () async {
    voice.nativeStartError = true;
    await session.onTalkStart();
    expect(session.isListening, isFalse);
    voice.nativeStartError = false;
    await session.onTalkStart();
    expect(session.isListening, isTrue);
    await session.onTalkEnd();
    expect(voice.stops, 1);
  });

  test('native stop error cleans up listening and permits retry', () async {
    await session.onTalkStart();
    voice.nativeStopError = true;
    await session.onTalkEnd();
    expect(session.isListening, isFalse);
    expect(voice.cancels, 1);
    voice.nativeStopError = false;
    await session.onTalkStart();
    expect(session.isListening, isTrue);
  });

  test('quick release waits for startup and stops once', () async {
    voice.startGate = Completer<void>();
    voice.text = 'cập nhật tuyến';
    final starting = session.onTalkStart();
    final ending = session.onTalkEnd();
    await session.onTalkEnd();
    await flushDeviceEvents();
    expect(voice.stops, 0);
    voice.startGate!.complete();
    await Future.wait([starting, ending]);
    expect(voice.stops, 1);
    expect(route.refreshes, 1);
  });

  test(
    'pause waits for startup before releasing the native recognizer',
    () async {
      voice.startGate = Completer<void>();
      final starting = session.onTalkStart();
      await flushDeviceEvents();
      final pausing = session.pauseNavigation();
      voice.startGate!.complete();
      await Future.wait([starting, pausing]);
      expect(voice.cancels, 1);
      expect(session.isListening, isFalse);
      await session.onTalkStart();
      expect(voice.starts, 1); // Paused sessions cannot reopen the microphone.
    },
  );

  test('old callbacks stay invalid after resume and a new recording', () async {
    final statuses = <String>[];
    final subscription = session.states.listen(
      (s) => statuses.add(s.statusText),
    );
    await session.onTalkStart();
    final oldCallback = voice.callbacks.single;
    await session.pauseNavigation();
    await session.resumeNavigation();
    await session.onTalkStart();
    oldCallback('old');
    voice.callbacks.last('new');
    await flushDeviceEvents();
    expect(statuses.where((s) => s.contains('old')), isEmpty);
    expect(statuses, contains('Đang nghe: new'));
    await subscription.cancel();
  });

  testWidgets('a second pointer cannot release the primary talk gesture', (
    tester,
  ) async {
    voice.text = 'cập nhật tuyến';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(height: 94, child: TalkButton(controller: session)),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(TalkButton));
    final first = await tester.startGesture(center, pointer: 1);
    final second = await tester.startGesture(
      center + const Offset(10, 0),
      pointer: 2,
    );
    await tester.pump();
    await second.up();
    await tester.pump();
    expect(voice.stops, 0);
    await first.up();
    await tester.pump();
    expect(voice.stops, 1);
    expect(route.refreshes, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(session.dispose);
  });
}

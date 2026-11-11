import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'warning wins when an older AI request is waiting on native stop',
    () async {
      const channel = MethodChannel('flutter_tts');
      final stopped = Completer<void>(), release = Completer<int>();
      final spoken = <String>[];
      var firstStop = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'stop' && firstStop) {
          firstStop = false;
          stopped.complete();
          return release.future;
        }
        if (call.method == 'speak') spoken.add(call.arguments as String);
        return 1;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final tts = TtsService();
      await tts.initialize();
      final old = tts.speak('AI cũ', priority: 0);
      await stopped.future;
      expect(await tts.speak('Cảnh báo mới', priority: 3), true);
      release.complete(1);
      expect(await old, false);
      expect(spoken, ['Cảnh báo mới']);
      await tts.dispose();
    },
  );
  test(
    'native speak failure releases priority and silence remains safe',
    () async {
      const channel = MethodChannel('flutter_tts');
      var failSpeak = true, failStop = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if ((call.method == 'speak' && failSpeak) ||
            (call.method == 'stop' && failStop)) {
          throw PlatformException(code: 'tts_unavailable');
        }
        return 1;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final tts = TtsService();
      await tts.initialize();
      expect(await tts.speak('warning', priority: 3), isFalse);
      failSpeak = false;
      expect(await tts.speak('assistant', priority: 0), isTrue);
      failStop = true;
      await tts.silence();
      await tts.dispose();
    },
  );
  group('speakers queue instead of cutting each other off', () {
    const channel = MethodChannel('flutter_tts');
    late List<String> spoken;
    late int stops;
    late TtsService tts;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // The native engine reporting that the current sentence ended by itself.
    Future<void> sentenceEnds() async {
      await messenger.handlePlatformMessage(
        'flutter_tts',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('speak.onComplete'),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
    }

    setUp(() async {
      spoken = [];
      stops = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'stop') stops++;
        if (call.method == 'speak') spoken.add(call.arguments as String);
        return 1;
      });
      tts = TtsService();
      await tts.initialize();
    });
    tearDown(() async {
      await tts.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('obstacle warning waits for the route sentence, and back', () async {
      expect(await tts.speak('Quay sang trái', priority: 1), isTrue);
      expect(await tts.speak('Có xe máy phía trước', priority: 3), isTrue);
      expect(spoken, ['Quay sang trái']);
      expect(stops, 1);
      await sentenceEnds();
      expect(spoken, ['Quay sang trái', 'Có xe máy phía trước']);

      expect(await tts.speak('Đi thẳng', priority: 1), isTrue);
      expect(spoken, hasLength(2));
      await sentenceEnds();
      expect(spoken.last, 'Đi thẳng');
    });

    test('high danger and prompts interrupt; same speaker replaces', () async {
      await tts.speak('Quay sang trái', priority: 1);
      await tts.speak('Chếch sang trái', priority: 1);
      expect(spoken, ['Quay sang trái', 'Chếch sang trái']);

      await tts.speak('Có xe ngay phía trước', priority: 3, interrupt: true);
      expect(spoken.last, 'Có xe ngay phía trước');
      await tts.speak('Nói xác nhận', priority: 4, interrupt: true);
      expect(spoken.last, 'Nói xác nhận');
    });

    test('anything may cut in on the assistant', () async {
      await tts.speak('Trợ lý đang giải thích', priority: 0);
      await tts.speak('Có người phía trước', priority: 3);
      expect(spoken, ['Trợ lý đang giải thích', 'Có người phía trước']);
      // The assistant does not cut in on the warning; it waits.
      await tts.speak('Trợ lý nói tiếp', priority: 0);
      expect(spoken, hasLength(2));
      await sentenceEnds();
      expect(spoken.last, 'Trợ lý nói tiếp');
    });

    test('the queue keeps the most important waiting sentence', () async {
      await tts.speak('Quay sang trái', priority: 1);
      await tts.speak('Có xe máy phía trước', priority: 3);
      await tts.speak('Trạng thái', priority: 2);
      await sentenceEnds();
      expect(spoken, ['Quay sang trái', 'Có xe máy phía trước']);
    });

    test('silence drops the waiting sentence', () async {
      await tts.speak('Quay sang trái', priority: 1);
      await tts.speak('Có xe máy phía trước', priority: 3);
      await tts.silence();
      await sentenceEnds();
      expect(spoken, ['Quay sang trái']);
      expect(await tts.speak('Đã kết thúc ghi âm', priority: 0), isTrue);
    });
  });
}

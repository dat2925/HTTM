import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'obstacle speech stops AI; lower priority is blocked until silence',
    () async {
      const channel = MethodChannel('flutter_tts');
      final spoken = <String>[];
      var stops = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'stop') stops++;
        if (call.method == 'speak') spoken.add(call.arguments as String);
        return 1;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final tts = TtsService();
      await tts.initialize();
      expect(await tts.speak('Trợ lý đang giải thích', priority: 0), isTrue);
      expect(
        await tts.speak('Có người rất gần phía trước', priority: 3),
        isTrue,
      );
      expect(stops, 2);
      expect(await tts.speak('Trợ lý nói tiếp', priority: 0), isFalse);
      expect(spoken, ['Trợ lý đang giải thích', 'Có người rất gần phía trước']);
      await tts.silence();
      expect(stops, 3);
      expect(await tts.speak('Đã kết thúc ghi âm', priority: 0), isTrue);
      await tts.dispose();
    },
  );
}

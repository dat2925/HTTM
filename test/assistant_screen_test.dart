import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/screens/assistant_screen.dart';
import 'package:smart_navigation/services/assistant_service.dart';
import 'assistant_test.dart' show FakeAssistant;
import 'session_navigation_test.dart' show FakeRoute, RecordingTts, NoCamera;

class PairingAssistant extends FakeAssistant {
  PairingAssistant() {
    enabled = false;
  }
  bool fail = true;
  Completer<void>? pendingPair;
  int pairCalls = 0;
  @override
  Future<void> pair(String code, {bool allowInsecure = false}) async {
    pairCalls++;
    await pendingPair?.future;
    if (fail) {
      throw const AssistantException('Mã không đúng. Hãy kiểm tra lại.');
    }
    enabled = true;
  }
}

void main() {
  testWidgets(
    'leaving pairing screen during request does not touch disposed input',
    (tester) async {
      final ai = PairingAssistant()
        ..fail = false
        ..pendingPair = Completer<void>();
      final session = SessionController(
        routeService: FakeRoute(),
        ttsService: RecordingTts(),
        frameSource: NoCamera(),
        assistantService: ai,
      );
      await tester.pumpWidget(
        MaterialApp(home: AssistantScreen(controller: session)),
      );
      await tester.enterText(find.byType(TextField), 'demo-code-123456');
      await tester.tap(find.widgetWithText(FilledButton, 'Ghép nối'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      ai.pendingPair!.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.runAsync(session.dispose);
    },
  );
  testWidgets('failed pairing retains input for editing and retry', (
    tester,
  ) async {
    final ai = PairingAssistant();
    final session = SessionController(
      routeService: FakeRoute(),
      ttsService: RecordingTts(),
      frameSource: NoCamera(),
      assistantService: ai,
    );
    await tester.pumpWidget(
      MaterialApp(home: AssistantScreen(controller: session)),
    );
    final field = find.byType(TextField);
    await tester.enterText(field, 'wrong-code-1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Ghép nối'));
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'wrong-code-1234');
    expect(find.text('Mã không đúng. Hãy kiểm tra lại.'), findsOneWidget);
    ai.fail = false;
    await tester.enterText(field, 'correct-code-1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Ghép nối'));
    await tester.pump();
    expect(ai.pairCalls, 2);
    expect(session.assistant.state.paired, isTrue);
    expect(find.text('Hỏi trợ lý'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(session.dispose);
  });
  testWidgets(
    'QR fills code without enrolling; canceled or bad scan keeps input',
    (tester) async {
      final ai = PairingAssistant();
      final route = FakeRoute();
      final session = SessionController(
        routeService: route,
        ttsService: RecordingTts(),
        frameSource: NoCamera(),
        assistantService: ai,
      );
      String? scan =
          '{"type":"smart_navigation_pairing","version":1,"pairing_code":"demo-code-123456"}';
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantScreen(controller: session, scanQr: (_) async => scan),
        ),
      );
      final field = find.byType(TextField);
      await tester.enterText(field, 'keep-this-code');
      await tester.tap(find.text('Quét QR'));
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'demo-code-123456',
      );
      expect(ai.pairCalls, 0);
      expect(route.stopped, 0);
      scan = null;
      await tester.tap(find.text('Quét QR'));
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'demo-code-123456',
      );
      scan = 'https://untrusted.example';
      await tester.tap(find.text('Quét QR'));
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'demo-code-123456',
      );
      expect(
        find.text('QR không hợp lệ. Mã đã nhập vẫn được giữ lại.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
    },
  );
  testWidgets('assistant screen handles keyboard and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SessionController(
      routeService: FakeRoute(),
      ttsService: RecordingTts(),
      frameSource: NoCamera(),
      assistantService: FakeAssistant(),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.5),
            viewInsets: const EdgeInsets.only(bottom: 280),
          ),
          child: child!,
        ),
        home: AssistantScreen(controller: session),
      ),
    );
    // No network or native camera is involved; this verifies the real conversation layout.
    await session.assistant.ask('Một câu hỏi kiểm tra');
    await tester.pump();
    expect(find.text('Hỏi trợ lý'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(session.dispose);
  });
}

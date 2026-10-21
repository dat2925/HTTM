import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/screens/ai_navigation_screen.dart';

import 'support/device_fakes.dart';

void main() {
  testWidgets('lifecycle releases camera and restores perception on resume', (
    tester,
  ) async {
    final camera = FakeCamera();
    final session = SessionController(
      frameSource: camera,
      detectionService: FakeDetector(),
      voiceService: FakeVoice(),
      ttsService: RecordingTts(),
    );
    await tester.pumpWidget(
      MaterialApp(home: AiNavigationScreen(controller: session)),
    );
    await tester.pump();
    expect(session.isRunning, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(session.isRunning, isFalse);
    expect(camera.ready, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.isRunning, isTrue);
    expect(camera.opened, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('manual stop stays stopped across background and foreground', (
    tester,
  ) async {
    final session = SessionController(
      frameSource: FakeCamera(),
      detectionService: FakeDetector(),
      voiceService: FakeVoice(),
      ttsService: RecordingTts(),
    );
    await tester.pumpWidget(
      MaterialApp(home: AiNavigationScreen(controller: session)),
    );
    await tester.pump();
    await tester.tap(find.text('Dừng'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.isRunning, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

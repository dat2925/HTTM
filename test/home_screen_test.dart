import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/models/route_progress.dart';
import 'package:smart_navigation/screens/home_screen.dart';
import 'package:smart_navigation/widgets/talk_button.dart';
import 'package:smart_navigation/models/assistant_state.dart';
import 'session_navigation_test.dart'
    show FakeRoute, RecordingTts, NoCamera, FakeVoice;
import 'assistant_test.dart' show FakeAssistant;

class PreviewSession extends SessionController {
  PreviewSession({super.assistantService, super.voiceService})
    : super(
        routeService: FakeRoute(),
        ttsService: RecordingTts(),
        frameSource: NoCamera(),
      );
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> start() async => false;
  @override
  RouteProgress get routeSnapshot => const RouteProgress(
    status: NavigationStatus.idle,
    message:
        'Đã tìm thấy vị trí. Chọn điểm đến hoặc nói đi đến địa điểm muốn tới.',
  );
}

void main() {
  testWidgets('primary microphone renders AI answer and proposal beside map', (
    tester,
  ) async {
    final voice = FakeVoice()..text = 'Gợi ý chỗ đi dạo';
    final ai = FakeAssistant()
      ..reply = AssistantReply(
        requestId: 'test',
        text: 'Bạn có thể tìm một công viên gần đây.',
        guidance: const AssistantGuidance(
          kind: 'situation',
          evidenceSources: ['user'],
          confidence: 'limited',
          priority: 0,
        ),
        expiresAt: DateTime.now().add(const Duration(seconds: 15)),
        proposals: [
          AssistantProposal(
            id: 'test',
            action: 'refresh_route',
            expiresAt: DateTime.now().add(const Duration(seconds: 45)),
          ),
        ],
      );
    final session = PreviewSession(assistantService: ai, voiceService: voice);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: session)));
    await tester.pump();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TalkButton)),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(ai.calls, 1);
    expect(
      find.text('Trợ lý: Bạn có thể tìm một công viên gần đây.'),
      findsOneWidget,
    );
    expect(find.text('Xác nhận thao tác'), findsOneWidget);
    expect(session.assistant.state.proposal, isNotNull);
    expect(find.textContaining('Nguồn'), findsWidgets);
    await tester.ensureVisible(find.text('Xác nhận thao tác'));
    await tester.tap(find.text('Xác nhận thao tác'));
    await tester.pump();
    expect(session.assistant.state.proposal, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets(
    'main screen supports a keyboard and enlarged text without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = PreviewSession();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.5),
              viewInsets: const EdgeInsets.only(bottom: 280),
            ),
            child: child!,
          ),
          home: HomeScreen(controller: session),
        ),
      );
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}

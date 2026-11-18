import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/models/perception_frame.dart';
import 'package:smart_navigation/widgets/perception_preview.dart';

void main() {
  testWidgets('stale boxes expire without a new detection event', (
    tester,
  ) async {
    final stream = StreamController<PerceptionFrame>.broadcast();
    var now = DateTime.utc(2026, 11, 18);
    await tester.pumpWidget(
      MaterialApp(
        home: PerceptionPreview(
          controller: null,
          frames: stream.stream,
          now: () => now,
        ),
      ),
    );
    stream.add(
      PerceptionFrame(
        objects: const [],
        imageWidth: 100,
        imageHeight: 100,
        fps: 1,
        latencyMs: 100,
        capturedAt: now,
        model: 'fixture',
      ),
    );
    await tester.pump();
    expect(find.textContaining('fixture'), findsOneWidget);
    now = now.add(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
    expect(find.textContaining('Detection đã cũ'), findsOneWidget);
    expect(find.textContaining('fixture'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await stream.close();
  });
  testWidgets('readout uses frame model/backend and independent timings', (
    tester,
  ) async {
    final stream = StreamController<PerceptionFrame>.broadcast();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 600,
          child: PerceptionPreview(controller: null, frames: stream.stream),
        ),
      ),
    );
    final at = DateTime.now().toUtc();
    final frame = PerceptionFrame(
      objects: [
        DetectedObject.fromJson({
          'class_name': 'pole',
          'confidence': .87,
          'position': 'center',
          'x1': 1,
          'y1': 2,
          'x2': 30,
          'y2': 50,
        }),
      ],
      imageWidth: 100,
      imageHeight: 200,
      fps: 1.1,
      latencyMs: 250,
      captureMs: 50,
      detectionMs: 190,
      inferenceMs: 100,
      backend: 'server',
      model: 'custom-s.pt',
      runtime: 'cpu',
      capturedAt: at,
    );
    stream.add(frame);
    await tester.pump();
    expect(find.textContaining('server · custom-s.pt'), findsOneWidget);
    expect(find.textContaining('1.1 FPS'), findsOneWidget);
    expect(find.textContaining('predict 100 ms'), findsOneWidget);
    final json = frame.toJson();
    expect(json['captured_at'], at.toIso8601String());
    expect((json['objects'] as List).single, containsPair('confidence', .87));
    await tester.pumpWidget(const SizedBox());
    await stream.close();
  });
}

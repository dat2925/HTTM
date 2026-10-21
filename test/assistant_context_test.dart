import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/assistant_controller.dart';
import 'package:smart_navigation/models/assistant_state.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/models/geo_point.dart';
import 'package:smart_navigation/models/route_progress.dart';

import 'assistant_test.dart' show FakeAssistant;

class ContextAssistant extends FakeAssistant {
  Map<String, dynamic>? context;
  Uint8List? image;

  @override
  Future<AssistantReply> chat(
    String message,
    Map<String, dynamic> context, {
    dynamic image,
    bool proactive = false,
    String? event,
  }) {
    this.context = context;
    this.image = image as Uint8List?;
    return super.chat(
      message,
      context,
      image: image,
      proactive: proactive,
      event: event,
    );
  }
}

void main() {
  test(
    'assistant receives GPS, walking route and fresh YOLO; image is opt-in',
    () async {
      final service = ContextAssistant();
      final now = DateTime.now();
      final progress = RouteProgress(
        status: NavigationStatus.navigating,
        position: const GeoPoint(21, 105),
        destination: const GeoPoint(21.001, 105.001),
        destinationName: 'Công viên',
        updatedAt: now,
        accuracyMeters: 5,
        headingDegrees: 90,
        remainingMeters: 150,
      );
      DateTime yoloAt = now;
      var captures = 0;
      final controller = AssistantController(
        service: service,
        snapshot: () => progress,
        detections: () => const [
          DetectedObject(
            className: 'person',
            confidence: .9,
            position: 'center',
            danger: DangerLevel.high,
            areaRatio: .2,
            x1: 1,
            y1: 1,
            x2: 10,
            y2: 10,
          ),
        ],
        yoloUpdatedAt: () => yoloAt,
        captureImage: () async {
          captures++;
          return AssistantImage(Uint8List.fromList([1, 2, 3]), DateTime.now());
        },
        onConfirmed: (_) async => fail('No route action was confirmed'),
        speak: (_) async => true,
        canSpeak: () => true,
        canProactivelyRequest: () => true,
      );
      addTearDown(controller.dispose);
      await controller.ask('Mô tả hành trình');
      expect(captures, 0);
      expect(service.image, isNull);
      expect(service.context!['position'], {'lat': 21.0, 'lng': 105.0});
      expect(service.context!['destination_name'], 'Công viên');
      expect(service.context!['remaining_meters'], 150);
      expect(
        (service.context!['obstacles'] as List).single['class_name'],
        'person',
      );
      await controller.ask('Phân tích ảnh', includeImage: true);
      expect(captures, 1);
      expect(service.image, [1, 2, 3]);
      expect(service.context!['image_captured_at'], isNotNull);
      yoloAt = now.subtract(const Duration(seconds: 10));
      await controller.ask('Mô tả ngữ cảnh hiện tại');
      expect(service.context!['obstacles'], isEmpty);
      expect(service.context!['yolo_updated_at'], isNull);
      expect(captures, 1);
    },
  );
}

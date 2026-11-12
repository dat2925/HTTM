import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/config/ai_config.dart';
import 'package:smart_navigation/services/on_device_detection_service.dart';

void main() {
  test('DEVICE_MODEL in .env selects the bundled model file', () {
    dotenv.loadFromString(envString: 'DEVICE_MODEL= yolo11n.tflite ');
    expect(AiConfig.deviceModel, 'yolo11n.tflite');
    expect(AiConfig.deviceModelAsset, 'assets/models/yolo11n.tflite');
  });

  test('missing or unsafe DEVICE_MODEL falls back to the custom model', () {
    for (final value in ['', '../secret.tflite', 'model.pt', 'a/b.tflite']) {
      dotenv.loadFromString(envString: 'DEVICE_MODEL=$value', isOptional: true);
      expect(AiConfig.deviceModel, AiConfig.defaultDeviceModel, reason: value);
    }
  });

  test('a model is usable when it knows at least one obstacle class', () {
    expect(modelLabelsUsable(['Nguoi', 'O ga', 'Cot']), isTrue);
    // COCO: most labels are not obstacles, a few are.
    expect(modelLabelsUsable(['banana', 'person', 'toaster']), isTrue);
    expect(modelLabelsUsable(['banana', 'toaster']), isFalse);
    expect(modelLabelsUsable(const <String>[]), isFalse);
    expect(modelLabelsUsable(null), isFalse);
  });
}

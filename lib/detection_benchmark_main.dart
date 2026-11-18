/// Explicit benchmark entry point; never starts navigation, GPS or speech.
/// flutter run -t lib/detection_benchmark_main.dart
///   --dart-define=BENCHMARK_MANIFEST=/app-readable/path/truth.jsonl
///   --dart-define=BENCHMARK_BACKEND=device
library;

import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'config/ai_config.dart';
import 'models/perception_frame.dart';
import 'services/ai_detection_service.dart';
import 'services/on_device_detection_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env.example');
  runApp(const MaterialApp(home: _BenchmarkScreen()));
}

class _BenchmarkScreen extends StatefulWidget {
  const _BenchmarkScreen();
  @override
  State<_BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<_BenchmarkScreen> {
  String status = 'Running labelled-image benchmark…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final device = OnDeviceDetector();
    final server = AiDetectionService();
    IOSink? sink;
    bool deviceUsed = false;
    try {
      const manifestPath = String.fromEnvironment('BENCHMARK_MANIFEST');
      const backend = String.fromEnvironment(
        'BENCHMARK_BACKEND',
        defaultValue: 'device',
      );
      if (manifestPath.isEmpty || !['device', 'server'].contains(backend)) {
        throw ArgumentError('Set BENCHMARK_MANIFEST and BENCHMARK_BACKEND');
      }
      final manifest = File(manifestPath);
      final output = File(
        '${manifest.path}.$backend.${DateTime.now().microsecondsSinceEpoch}.jsonl',
      );
      if (backend == 'device') {
        deviceUsed = true;
        await device.prepare();
      }
      sink = output.openWrite();
      final ids = <String>{};
      for (final line in await manifest.readAsLines()) {
        if (line.trim().isEmpty) continue;
        final row = jsonDecode(line) as Map<String, dynamic>;
        final id = row['frame_id'] as String;
        if (!ids.add(id)) throw FormatException('Duplicate frame_id: $id');
        final image = File('${manifest.parent.path}/${row['image']}');
        final clock = Stopwatch()..start();
        final result = backend == 'device'
            ? await device.detect(XFile(image.path))
            : await server.detect(XFile(image.path));
        final frame = PerceptionFrame(
          objects: result.objects,
          imageWidth: result.imageWidth,
          imageHeight: result.imageHeight,
          fps: 0,
          latencyMs: clock.elapsedMilliseconds,
          backend: backend,
          model:
              result.model ??
              (backend == 'device' ? AiConfig.deviceModel : 'unknown'),
          runtime: result.runtime ?? 'unknown',
          inferenceMs: result.inferenceMs,
        );
        sink.writeln(jsonEncode({...frame.toJson(), 'frame_id': id}));
        await sink.flush();
      }
      if (mounted) {
        setState(
          () => status = 'Completed ${ids.length} frames\n${output.path}',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => status =
              'Benchmark failed (partial output is not a complete run): $error',
        );
      }
    } finally {
      await sink?.close();
      if (deviceUsed) await device.dispose();
      server.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Detection V2 benchmark')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: SelectableText(status),
    ),
  );
}

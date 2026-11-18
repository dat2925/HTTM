import 'package:camera/camera.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'camera_frame_adapter.dart';

import '../config/ai_config.dart';

/// Owns the single [CameraController] shared by the live preview widget and
/// the periodic AI capture, so the app never opens two camera streams.
class FrameSource {
  CameraController? _controller;
  CameraImage? _latestFrame;
  DateTime? _latestAt;
  DateTime? lastCapturedAt;
  Completer<void>? _nextFrame;
  int _generation = 0;
  bool get usingStream => _controller?.value.isStreamingImages ?? false;

  CameraController? get controller => _controller;

  bool get isReady => _controller?.value.isInitialized ?? false;

  Future<void> initialize() async {
    final cameras = await availableCameras().timeout(
      AiConfig.cameraInitTimeout,
      onTimeout: () => throw CameraException(
        'cameraInitTimeout',
        'Camera initialization timed out.',
      ),
    );
    if (cameras.isEmpty) {
      throw CameraException('noCamera', 'No camera available on this device.');
    }
    final camera = cameras.firstWhere(
      (item) => item.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: const bool.fromEnvironment('CAMERA_STREAM')
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.jpeg,
    );
    await dispose();
    try {
      await controller.initialize().timeout(
        AiConfig.cameraInitTimeout,
        onTimeout: () => throw CameraException(
          'cameraInitTimeout',
          'Camera initialization timed out.',
        ),
      );
    } catch (_) {
      await controller.dispose();
      rethrow;
    }
    _controller = controller;
    if (const bool.fromEnvironment('CAMERA_STREAM')) {
      // Keep the experimental adapter scoped to the Android back camera.
      if (Platform.isAndroid &&
          camera.lensDirection == CameraLensDirection.back &&
          controller.supportsImageStreaming()) {
        try {
          await controller.startImageStream((image) {
            _latestFrame = image;
            _latestAt = DateTime.now();
            final waiting = _nextFrame;
            _nextFrame = null;
            if (waiting != null && !waiting.isCompleted) waiting.complete();
          });
        } catch (_) {
          // Snapshot capture remains available when streaming cannot start.
          _latestFrame = null;
        }
      }
    }
  }

  Future<XFile> captureFrame() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw CameraException('notInitialized', 'Camera is not ready.');
    }
    if (usingStream) {
      try {
        return await _captureStream(controller);
      } on FormatException {
        await controller.stopImageStream();
        _latestFrame = null;
      } on CameraException catch (error) {
        if (error.code != 'streamFormat') rethrow;
        await controller.stopImageStream();
        _latestFrame = null;
      }
    }
    final image = await controller.takePicture().timeout(
      AiConfig.captureTimeout,
      onTimeout: () =>
          throw CameraException('captureTimeout', 'Camera capture timed out.'),
    );
    lastCapturedAt = DateTime.now();
    return image;
  }

  Future<XFile> _captureStream(CameraController controller) async {
    final conversionClock = Stopwatch()..start();
    final generation = _generation;
    if (_latestFrame == null) {
      final waiting = _nextFrame ??= Completer<void>();
      await waiting.future.timeout(AiConfig.captureTimeout);
    }
    final image = _latestFrame;
    final at = _latestAt;
    _latestFrame = null;
    if (generation != _generation ||
        image == null ||
        at == null ||
        DateTime.now().difference(at) > const Duration(seconds: 1)) {
      throw CameraException('staleFrame', 'No fresh stream frame available.');
    }
    if (image.format.group != ImageFormatGroup.yuv420 &&
        image.format.group != ImageFormatGroup.bgra8888) {
      throw CameraException('streamFormat', 'Unsupported stream image format.');
    }
    final orientation = controller.value.deviceOrientation;
    final degrees = switch (orientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    final bytes = await encodeCameraFrame(
      CameraFramePacket(
        width: image.width,
        height: image.height,
        rotation:
            (controller.description.sensorOrientation - degrees + 360) % 360,
        bgra: image.format.group == ImageFormatGroup.bgra8888,
        planes: [for (final p in image.planes) Uint8List.fromList(p.bytes)],
        rowStrides: [for (final p in image.planes) p.bytesPerRow],
        pixelStrides: [for (final p in image.planes) p.bytesPerPixel ?? 1],
      ),
    );
    if (generation != _generation ||
        conversionClock.elapsed >= AiConfig.captureTimeout) {
      throw CameraException('stopped', 'Camera changed.');
    }
    final file = File(
      '${Directory.systemTemp.path}/httm-frame-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes, flush: false);
    lastCapturedAt = at;
    return XFile(file.path);
  }

  Future<void> dispose() async {
    _generation++;
    _latestFrame = null;
    _latestAt = null;
    lastCapturedAt = null;
    final waiting = _nextFrame;
    _nextFrame = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    await _controller?.dispose();
    _controller = null;
  }
}

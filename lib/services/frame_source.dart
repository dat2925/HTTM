import 'package:camera/camera.dart';

/// Owns the single [CameraController] shared by the live preview widget and
/// the periodic AI capture, so the app never opens two camera streams.
class FrameSource {
  CameraController? _controller;

  CameraController? get controller => _controller;

  bool get isReady => _controller?.value.isInitialized ?? false;

  Future<void> initialize() async {
    final cameras = await availableCameras();
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
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await controller.initialize();
    await _controller?.dispose();
    _controller = controller;
  }

  Future<XFile> captureFrame() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw CameraException('notInitialized', 'Camera is not ready.');
    }
    return controller.takePicture();
  }

  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
  }
}

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/ai_config.dart';
import '../models/detection_result.dart';
import '../services/ai_detection_service.dart';
import '../services/obstacle_reasoning_service.dart';
import '../services/tts_service.dart';

class AiNavigationScreen extends StatefulWidget {
  const AiNavigationScreen({super.key});

  @override
  State<AiNavigationScreen> createState() => _AiNavigationScreenState();
}

class _AiNavigationScreenState extends State<AiNavigationScreen>
    with WidgetsBindingObserver {
  final AiDetectionService _detectionService = AiDetectionService();
  final ObstacleReasoningService _reasoningService = ObstacleReasoningService();
  final TtsService _ttsService = TtsService();

  CameraController? _cameraController;
  Timer? _captureTimer;
  bool _cameraInitializing = true;
  bool _aiRunning = false;
  bool _requestInProgress = false;
  String _status = 'Đang khởi tạo camera...';
  String _latestWarning = 'Nhấn Start AI để bắt đầu.';
  List<DetectedObject> _objects = const [];
  String? _lastSpokenWarning;
  DateTime? _lastSpokenAt;
  DangerLevel? _lastSpokenDanger;
  int _emptyCycles = 0;
  bool _wasDangerous = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ttsService.initialize();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (mounted) {
      setState(() {
        _cameraInitializing = true;
        _status = 'Đang khởi tạo camera...';
      });
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('noCamera', 'No camera');
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
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await _cameraController?.dispose();
      setState(() {
        _cameraController = controller;
        _cameraInitializing = false;
        _status = 'Camera sẵn sàng';
      });
    } on CameraException {
      if (!mounted) return;
      setState(() {
        _cameraInitializing = false;
        _status = 'Không thể mở camera. Hãy cấp quyền camera.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cameraInitializing = false;
        _status = 'Không tìm thấy camera.';
      });
    }
  }

  Future<void> _startAi() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _aiRunning) {
      return;
    }
    setState(() => _status = 'Đang kiểm tra AI Server...');
    final healthy = await _detectionService.isHealthy();
    if (!mounted) return;
    if (!healthy) {
      setState(() => _status = 'Không thể kết nối AI Server.');
      return;
    }
    setState(() {
      _aiRunning = true;
      _status = 'AI đang chạy';
    });
    _captureTimer = Timer.periodic(
      AiConfig.captureInterval,
      (_) => _captureAndDetect(),
    );
    await _captureAndDetect();
  }

  void _stopAi() {
    _captureTimer?.cancel();
    _captureTimer = null;
    if (!mounted) return;
    setState(() {
      _aiRunning = false;
      _status = 'AI đã dừng';
    });
  }

  Future<void> _captureAndDetect() async {
    final controller = _cameraController;
    if (!_aiRunning ||
        _requestInProgress ||
        controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture) {
      return;
    }
    _requestInProgress = true;
    XFile? image;
    try {
      image = await controller.takePicture();
      final result = await _detectionService.detect(image);
      if (!mounted || !_aiRunning) return;
      await _processResult(result);
    } on CameraException {
      if (mounted && _aiRunning) {
        setState(() => _status = 'Lỗi chụp ảnh từ camera.');
      }
    } on AiDetectionException catch (error) {
      if (mounted && _aiRunning) setState(() => _status = error.message);
    } finally {
      _requestInProgress = false;
      if (image != null) {
        try {
          await File(image.path).delete();
        } catch (_) {
          // Camera cache cleanup is best-effort only.
        }
      }
    }
  }

  Future<void> _processResult(DetectionResult result) async {
    final warning = _reasoningService.selectWarning(result.objects);
    if (warning == null) {
      _emptyCycles++;
      if (_emptyCycles >= AiConfig.safeCyclesRequired) {
        final shouldSpeakSafe = _wasDangerous;
        _wasDangerous = false;
        setState(() {
          _objects = const [];
          _latestWarning = 'Phía trước chưa phát hiện vật cản.';
          _status = 'AI đang chạy';
        });
        if (shouldSpeakSafe) {
          await _ttsService.speak('Phía trước an toàn.');
          _lastSpokenWarning = 'Phía trước an toàn.';
          _lastSpokenAt = DateTime.now();
          _lastSpokenDanger = null;
        }
      }
      return;
    }

    _emptyCycles = 0;
    _wasDangerous = true;
    setState(() {
      _objects = result.objects;
      _latestWarning = warning.text;
      _status = 'AI đang chạy';
    });

    final now = DateTime.now();
    final sameWarningCoolingDown =
        _lastSpokenWarning == warning.text &&
        _lastSpokenAt != null &&
        now.difference(_lastSpokenAt!) < AiConfig.warningCooldown;
    final canInterrupt =
        warning.danger == DangerLevel.high &&
        _lastSpokenDanger != DangerLevel.high;
    if (!sameWarningCoolingDown || canInterrupt) {
      if (warning.danger == DangerLevel.high) {
        await HapticFeedback.heavyImpact();
      } else if (warning.danger == DangerLevel.medium) {
        await HapticFeedback.mediumImpact();
      }
      await _ttsService.speak(warning.text);
      _lastSpokenWarning = warning.text;
      _lastSpokenAt = now;
      _lastSpokenDanger = warning.danger;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopAi();
      _cameraController?.dispose();
      _cameraController = null;
    } else if (state == AppLifecycleState.resumed &&
        _cameraController == null) {
      _initializeCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _captureTimer?.cancel();
    _cameraController?.dispose();
    _detectionService.dispose();
    _ttsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Navigation')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AspectRatio(
              aspectRatio: _cameraController?.value.aspectRatio ?? 3 / 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: ColoredBox(color: Colors.black, child: _buildCamera()),
              ),
            ),
            const SizedBox(height: 16),
            _InfoCard(label: 'Trạng thái', value: _status),
            const SizedBox(height: 10),
            _InfoCard(label: 'Cảnh báo', value: _latestWarning),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Phát hiện',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (_objects.isEmpty)
                      const Text('Chưa có vật cản')
                    else
                      ..._objects.map(
                        (object) => Text(
                          '${object.className} • '
                          '${_positionLabel(object.position)} • '
                          '${object.danger.label} • '
                          '${(object.confidence * 100).round()}%',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: !_aiRunning && !_cameraInitializing
                        ? _startAi
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start AI'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _aiRunning ? _stopAi : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop AI'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Server: ${AiConfig.serverUrl}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCamera() {
    final controller = _cameraController;
    if (_cameraInitializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: Icon(Icons.no_photography, size: 56));
    }
    return CameraPreview(controller);
  }

  String _positionLabel(String position) => switch (position) {
    'left' => 'Trái',
    'right' => 'Phải',
    _ => 'Giữa',
  };
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(value, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

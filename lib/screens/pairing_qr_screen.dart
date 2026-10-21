import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/pairing_qr.dart';

class PairingQrScreen extends StatefulWidget {
  const PairingQrScreen({super.key, required this.scanner});
  final MobileScannerController scanner;

  /// Own the scanner outside the route so native camera disposal completes
  /// before SessionController is allowed to reclaim it.
  static Future<String?> scan(BuildContext context) async {
    final scanner = MobileScannerController(
      autoStart: false,
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    final route = MaterialPageRoute<String>(
      builder: (_) => PairingQrScreen(scanner: scanner),
    );
    try {
      final result = await Navigator.of(context).push(route);
      await route.completed;
      return result;
    } finally {
      await scanner.dispose();
    }
  }

  @override
  State<PairingQrScreen> createState() => _PairingQrScreenState();
}

class _PairingQrScreenState extends State<PairingQrScreen>
    with WidgetsBindingObserver {
  bool _accepted = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    if (!mounted || _accepted) return;
    try {
      await widget.scanner.start();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Không mở được camera. Bạn có thể quay lại để nhập hoặc dán mã.',
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.scanner.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_start());
    } else {
      unawaited(widget.scanner.stop());
    }
  }

  void _detect(BarcodeCapture capture) {
    if (_accepted || !mounted) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw != null && PairingQr.codeFrom(raw) != null) {
        _accepted = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
    setState(() => _error = 'QR này không phải mã ghép nối hợp lệ.');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Quét QR ghép nối')),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Đưa QR vào camera. Camera cảnh báo vật cản tạm dừng khi quét; hãy đứng yên để ghép nối.',
            ),
          ),
          Expanded(
            child: MobileScanner(
              controller: widget.scanner,
              onDetect: _detect,
              errorBuilder: (_, error) => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Chưa truy cập được camera. Hãy kiểm tra quyền camera hoặc quay lại nhập mã.',
                  ),
                ),
              ),
            ),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

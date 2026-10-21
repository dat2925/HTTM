import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/session_controller.dart';
import '../models/session_state.dart';
import '../widgets/perception_preview.dart';
import '../widgets/status_panel.dart';
import '../widgets/talk_button.dart';

/// Standalone device demo. The navigation/assistant owners provide their own UI.
class AiNavigationScreen extends StatefulWidget {
  const AiNavigationScreen({super.key, this.controller, this.scanQr});
  final SessionController? controller;
  final Future<void> Function(BuildContext context)? scanQr;

  @override
  State<AiNavigationScreen> createState() => _AiNavigationScreenState();
}

class _AiNavigationScreenState extends State<AiNavigationScreen>
    with WidgetsBindingObserver {
  late final SessionController _session =
      widget.controller ?? SessionController();
  bool _initializing = true, _scanning = false, _backgrounded = false;
  bool _autoStartPending = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _session.initialize();
      if (mounted && !_backgrounded) {
        _autoStartPending = false;
        await _session.start();
      }
    } catch (_) {
      _error =
          'Chưa khởi tạo được thiết bị. Hãy kiểm tra quyền camera và micro.';
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgrounded = true;
      unawaited(_session.pause());
    } else if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      unawaited(_resume());
    }
  }

  Future<void> _resume() async {
    try {
      await _session.resume();
      if (mounted && !_initializing && _autoStartPending) {
        _autoStartPending = false;
        await _session.start();
      }
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = 'Chưa khôi phục được thiết bị.');
    }
  }

  Future<void> _scanQr() async {
    if (_scanning || widget.scanQr == null) return;
    setState(() => _scanning = true);
    bool? restart;
    try {
      restart = await _session.suspendCameraForQr();
      if (!mounted) return;
      await widget.scanQr!(context);
    } catch (_) {
      if (mounted) setState(() => _error = 'Chưa mở được bộ quét QR.');
    } finally {
      if (restart != null) {
        await _session.resumeCameraAfterQr(restartPerception: restart);
      }
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Camera cảnh báo vật cản')),
    body: SafeArea(
      child: StreamBuilder<SessionState>(
        stream: _session.states,
        initialData: _session.state,
        builder: (context, snapshot) => Column(
          children: [
            Expanded(
              child: PerceptionPreview(
                controller: _session.cameraController,
                frames: _session.frames,
              ),
            ),
            StatusPanel(state: snapshot.data ?? const SessionIdle()),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  onPressed: _initializing || _scanning
                      ? null
                      : () => unawaited(_session.start()),
                  child: const Text('Bắt đầu'),
                ),
                OutlinedButton(
                  onPressed: _session.stop,
                  child: const Text('Dừng'),
                ),
                if (widget.scanQr != null)
                  OutlinedButton(
                    onPressed: _initializing || _scanning ? null : _scanQr,
                    child: const Text('Quét QR'),
                  ),
              ],
            ),
            TalkButton(controller: _session),
          ],
        ),
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_session.dispose());
    super.dispose();
  }
}

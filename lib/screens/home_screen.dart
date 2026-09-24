import 'package:flutter/material.dart';

import '../config/ai_config.dart';
import '../controllers/session_controller.dart';
import '../models/session_state.dart';
import '../widgets/perception_preview.dart';
import '../widgets/status_panel.dart';
import '../widgets/talk_button.dart';
import 'route_debug_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final SessionController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _demoMode = true;
  bool _initializing = true;
  String? _initError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    try {
      await widget.controller.initialize();
      await widget.controller.start();
    } catch (_) {
      _initError = 'Không thể mở camera. Hãy cấp quyền camera.';
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      widget.controller.stop();
    } else if (state == AppLifecycleState.resumed && !_initializing) {
      widget.controller.start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Navigation'),
        actions: [
          IconButton(
            tooltip: 'Route debug',
            icon: const Icon(Icons.route),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => RouteDebugScreen(controller: widget.controller),
              ),
            ),
          ),
          IconButton(
            tooltip: _demoMode ? 'Chuyển sang Blind mode' : 'Chuyển sang Demo mode',
            icon: Icon(_demoMode ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _demoMode = !_demoMode),
          ),
        ],
      ),
      body: SafeArea(
        child: _initializing
            ? const Center(child: CircularProgressIndicator())
            : _initError != null
            ? Center(child: Text(_initError!))
            : Column(
                children: [
                  if (_demoMode)
                    Expanded(
                      flex: 9,
                      child: PerceptionPreview(
                        controller: widget.controller.cameraController,
                        frames: widget.controller.frames,
                      ),
                    ),
                  Expanded(
                    flex: 3,
                    child: StreamBuilder<SessionState>(
                      stream: widget.controller.states,
                      initialData: const SessionIdle(),
                      builder: (_, snapshot) =>
                          StatusPanel(state: snapshot.data!),
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: TalkButton(controller: widget.controller),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Server: ${AiConfig.serverUrl}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

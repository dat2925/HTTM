import 'dart:async';
import 'package:flutter/material.dart';
import '../controllers/session_controller.dart';
import '../models/geo_point.dart';
import '../models/placemark.dart';
import '../models/route_progress.dart';
import '../models/session_state.dart';
import '../services/route_service.dart';
import '../widgets/navigation_map.dart';
import '../widgets/perception_preview.dart';
import '../widgets/talk_button.dart';
import 'route_debug_screen.dart';
import 'assistant_screen.dart';
import '../widgets/assistant_panel.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _destinationInput = TextEditingController();
  bool _cameraView = false, _searching = false, _initializing = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      await widget.controller.initialize();
      if (!mounted) return;
      await widget.controller.start();
    } catch (_) {
      _error = 'Chưa khởi tạo được ứng dụng. Hãy kiểm tra quyền thiết bị.';
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _search() async {
    final query = _destinationInput.text.trim();
    if (query.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final place = await widget.controller.findDestination(query);
      if (mounted) await _confirm(place);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _confirm(Placemark place) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Đi bộ tới địa điểm này?'),
        content: Text(place.displayName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Dẫn đường'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) await widget.controller.navigateTo(place);
  }

  Future<void> _pickOnMap(GeoPoint point) => _confirm(
    Placemark(
      lat: point.lat,
      lng: point.lng,
      displayName:
          'Điểm trên bản đồ (${point.lat.toStringAsFixed(5)}, ${point.lng.toStringAsFixed(5)})',
    ),
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      widget.controller.pauseNavigation();
    } else if (state == AppLifecycleState.resumed && !_initializing) {
      unawaited(widget.controller.resumeNavigation());
      unawaited(widget.controller.start());
    }
  }

  void _openAssistant() => unawaited(
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AssistantScreen(controller: widget.controller),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Dẫn đường đi bộ'),
      actions: [
        IconButton(
          tooltip: 'Trợ lý AI',
          icon: const Icon(Icons.chat_bubble_outline),
          onPressed: _openAssistant,
        ),
        IconButton(
          tooltip: _cameraView ? 'Mở bản đồ' : 'Xem camera',
          icon: Icon(_cameraView ? Icons.map : Icons.camera_alt),
          onPressed: () => setState(() => _cameraView = !_cameraView),
        ),
        IconButton(
          tooltip: 'Chi tiết hành trình',
          icon: const Icon(Icons.route),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RouteDebugScreen(controller: widget.controller),
            ),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: StreamBuilder<RouteProgress>(
        stream: widget.controller.routeProgress,
        initialData: widget.controller.routeSnapshot,
        builder: (context, snapshot) {
          final p = snapshot.data!;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _destinationInput,
                        onSubmitted: (_) => _search(),
                        decoration: const InputDecoration(
                          labelText: 'Bạn muốn đi bộ tới đâu?',
                          hintText: 'Nhập địa điểm hoặc nhấn giữ để nói',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Tìm địa điểm',
                      onPressed: _searching ? null : _search,
                      icon: _searching
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                    ),
                  ],
                ),
              ),
              if (_initializing) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.orange),
                  ),
                ),
              Expanded(
                child: _cameraView
                    ? widget.controller.cameraController == null
                          ? Center(
                              child: Text(
                                widget.controller.cameraError ??
                                    'Đang mở camera...',
                              ),
                            )
                          : PerceptionPreview(
                              controller: widget.controller.cameraController,
                              frames: widget.controller.frames,
                            )
                    : NavigationMap(
                        progress: p,
                        onDestinationPicked: (point) =>
                            unawaited(_pickOnMap(point)),
                      ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          p.message,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Đã đi ${p.walkedMeters.round()} m · Còn ${p.remainingMeters.round()} m'
                          ' · GPS ±${p.accuracyMeters?.round() ?? '—'} m',
                        ),
                        Text(
                          p.headingDegrees == null
                              ? 'Hướng chưa rõ: giữ đầu điện thoại về phía trước, tránh gần kim loại.'
                              : 'Đầu điện thoại: ${cardinalDirection(p.headingDegrees!)} ${p.headingDegrees!.round()}°'
                                    '${p.targetBearing == null ? '' : ' · Lối đi: ${p.targetBearing!.round()}°'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        StreamBuilder<SessionState>(
                          stream: widget.controller.states,
                          builder: (_, state) {
                            final alert = state.data;
                            if (alert is SessionAlerting) {
                              return Text(
                                alert.statusText,
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              );
                            }
                            if (widget.controller.pendingDestination != null) {
                              return Column(
                                children: [
                                  Text(
                                    widget
                                        .controller
                                        .pendingDestination!
                                        .displayName,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      TextButton(
                                        onPressed: widget
                                            .controller
                                            .cancelPendingDestination,
                                        child: const Text('Hủy'),
                                      ),
                                      FilledButton(
                                        onPressed: widget
                                            .controller
                                            .confirmPendingDestination,
                                        child: const Text('Xác nhận đích'),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            }
                            if (widget.controller.cameraError != null) {
                              return Text(
                                widget.controller.cameraError!,
                                style: const TextStyle(color: Colors.orange),
                              );
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                        const Divider(),
                        AssistantPanel(
                          controller: widget.controller,
                          onOpen: _openAssistant,
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              tooltip: 'Tôi đang ở đâu?',
                              onPressed: widget.controller.describeLocation,
                              icon: const Icon(Icons.my_location),
                            ),
                            IconButton(
                              tooltip: 'Đọc lại hướng dẫn',
                              onPressed: widget.controller.repeatInstruction,
                              icon: const Icon(Icons.volume_up),
                            ),
                            IconButton(
                              tooltip: 'Cập nhật tuyến đi bộ',
                              onPressed: () async {
                                await widget.controller.resumeNavigation();
                                await widget.controller.refreshRoute();
                              },
                              icon: const Icon(Icons.refresh),
                            ),
                            IconButton(
                              tooltip: 'Hủy điểm đến',
                              onPressed: p.destination == null
                                  ? null
                                  : widget.controller.cancelDestination,
                              icon: const Icon(Icons.stop_circle_outlined),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (MediaQuery.viewInsetsOf(context).bottom == 0)
                SizedBox(
                  height: 94,
                  child: TalkButton(controller: widget.controller),
                ),
            ],
          );
        },
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _destinationInput.dispose();
    unawaited(widget.controller.dispose());
    super.dispose();
  }
}

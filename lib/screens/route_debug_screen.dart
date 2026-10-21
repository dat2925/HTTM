import 'package:flutter/material.dart';
import '../controllers/session_controller.dart';
import '../models/route_progress.dart';
import '../widgets/navigation_map.dart';

class RouteDebugScreen extends StatelessWidget {
  const RouteDebugScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Hành trình đi bộ'),
      actions: [
        IconButton(
          tooltip: 'Xóa đoạn đường đã lưu',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            final clear = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Xóa hành trình đã đi?'),
                content: const Text(
                  'Đường đi đã lưu trên thiết bị sẽ được xóa.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Hủy'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Xóa'),
                  ),
                ],
              ),
            );
            if (clear == true) await controller.clearJourney();
          },
        ),
      ],
    ),
    body: StreamBuilder<RouteProgress>(
      stream: controller.routeProgress,
      initialData: controller.routeSnapshot,
      builder: (_, snapshot) {
        final p = snapshot.data!;
        return Column(
          children: [
            Expanded(child: NavigationMap(progress: p)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '${p.message}\n${p.position == null ? 'Chưa có vị trí' : '${p.currentLat.toStringAsFixed(6)}, ${p.currentLng.toStringAsFixed(6)}'}'
                ' · GPS ±${p.accuracyMeters?.round() ?? '—'} m\n'
                'Đã đi ${p.walkedMeters.round()} m · Còn ${p.remainingMeters.round()} m\n'
                'Cập nhật tuyến: ${p.lastRouteUpdate?.toLocal().toString().split('.').first ?? 'chưa có'}',
              ),
            ),
            SizedBox(
              height: 170,
              child: ListView.builder(
                itemCount: p.waypoints.length,
                itemBuilder: (_, index) => ListTile(
                  dense: true,
                  leading: Icon(
                    index < p.currentIndex
                        ? Icons.check_circle
                        : Icons.directions_walk,
                    color: index == p.currentIndex ? Colors.orange : null,
                  ),
                  title: Text(p.waypoints[index].instruction),
                  subtitle: Text(
                    '${p.waypoints[index].distanceMeters.round()} m theo lối đi',
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

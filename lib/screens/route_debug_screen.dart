import 'package:flutter/material.dart';

import '../controllers/session_controller.dart';
import '../models/route_progress.dart';
import '../widgets/route_debug_map.dart';

/// Dev/demo-only screen: visualizes route-following state (waypoint list,
/// active step, real GPS position) that TTS alone doesn't make easy to
/// verify. Reached from a button on [HomeScreen], never shown to the
/// blind end user.
class RouteDebugScreen extends StatelessWidget {
  const RouteDebugScreen({super.key, required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Route debug')),
      body: StreamBuilder<RouteProgress>(
        stream: controller.routeProgress,
        builder: (context, snapshot) {
          final progress = snapshot.data;
          if (progress == null) {
            return const Center(
              child: Text('Chưa có dữ liệu route (chưa có GPS hoặc đích).'),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                RouteDebugMap(progress: progress),
                const SizedBox(height: 12),
                Text(
                  'Vị trí hiện tại: '
                  '${progress.currentLat.toStringAsFixed(6)}, '
                  '${progress.currentLng.toStringAsFixed(6)}  ·  '
                  'còn ${progress.remainingMeters.round()} m tới bước kế tiếp',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.separated(
                    itemCount: progress.waypoints.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final waypoint = progress.waypoints[index];
                      final isCurrent = index == progress.currentIndex;
                      final isDone = index < progress.currentIndex;
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 12,
                          backgroundColor: isCurrent
                              ? Colors.orangeAccent
                              : (isDone ? Colors.greenAccent : null),
                          child: Text('${index + 1}'),
                        ),
                        title: Text(
                          waypoint.instruction,
                          style: isCurrent
                              ? const TextStyle(fontWeight: FontWeight.bold)
                              : null,
                        ),
                        subtitle: Text(
                          '${waypoint.distanceMeters.round()} m · '
                          '${waypoint.lat.toStringAsFixed(5)}, '
                          '${waypoint.lng.toStringAsFixed(5)}',
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

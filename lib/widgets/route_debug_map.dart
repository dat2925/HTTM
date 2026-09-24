import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/route_progress.dart';

/// Schematic (not a real map tile) top-down view of the route: waypoints
/// projected from lat/lng onto a flat canvas with an equirectangular
/// approximation, good enough for the short distances a demo covers.
class RouteDebugMap extends StatelessWidget {
  const RouteDebugMap({super.key, required this.progress});

  final RouteProgress progress;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: CustomPaint(painter: _RoutePainter(progress: progress)),
      ),
    );
  }
}

class _RoutePainter extends CustomPainter {
  _RoutePainter({required this.progress});

  final RouteProgress progress;

  @override
  void paint(Canvas canvas, Size size) {
    final points = [
      ...progress.waypoints.map((w) => (lat: w.lat, lng: w.lng)),
      (lat: progress.currentLat, lng: progress.currentLng),
    ];
    if (points.isEmpty) return;

    final originLat = points.first.lat;
    final cosLat = math.cos(originLat * math.pi / 180);
    Offset project(double lat, double lng) {
      final x = (lng - points.first.lng) * cosLat;
      final y = -(lat - originLat);
      return Offset(x, y);
    }

    final projected = points.map((p) => project(p.lat, p.lng)).toList();
    var minX = projected.first.dx, maxX = projected.first.dx;
    var minY = projected.first.dy, maxY = projected.first.dy;
    for (final p in projected) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final spanX = (maxX - minX).abs() < 1e-9 ? 1e-9 : maxX - minX;
    final spanY = (maxY - minY).abs() < 1e-9 ? 1e-9 : maxY - minY;
    const padding = 24.0;
    final scale = math.min(
      (size.width - padding * 2) / spanX,
      (size.height - padding * 2) / spanY,
    );
    Offset toCanvas(Offset p) => Offset(
      padding + (p.dx - minX) * scale,
      padding + (p.dy - minY) * scale,
    );

    final waypointPoints = projected
        .take(progress.waypoints.length)
        .map(toCanvas)
        .toList();
    final currentPoint = toCanvas(projected.last);

    final linePaint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 2;
    for (var i = 0; i < waypointPoints.length - 1; i++) {
      canvas.drawLine(waypointPoints[i], waypointPoints[i + 1], linePaint);
    }

    for (var i = 0; i < waypointPoints.length; i++) {
      final isCurrent = i == progress.currentIndex;
      final isDone = i < progress.currentIndex;
      canvas.drawCircle(
        waypointPoints[i],
        isCurrent ? 7 : 5,
        Paint()
          ..color = isCurrent
              ? Colors.orangeAccent
              : (isDone ? Colors.greenAccent : Colors.white54),
      );
    }

    canvas.drawCircle(
      currentPoint,
      8,
      Paint()..color = Colors.blueAccent,
    );
    canvas.drawCircle(
      currentPoint,
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _RoutePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

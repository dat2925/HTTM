import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/geo_point.dart';
import '../models/route_progress.dart';

class NavigationMap extends StatefulWidget {
  const NavigationMap({
    super.key,
    required this.progress,
    this.onDestinationPicked,
    this.tileProvider,
  });
  final RouteProgress progress;
  final ValueChanged<GeoPoint>? onDestinationPicked;
  final TileProvider? tileProvider;
  @override
  State<NavigationMap> createState() => _NavigationMapState();
}

class _NavigationMapState extends State<NavigationMap> {
  final MapController _map = MapController();
  bool _ready = false, _follow = true;
  bool _tileError = false;
  LatLng _latLng(GeoPoint p) => LatLng(p.lat, p.lng);
  @override
  void didUpdateWidget(covariant NavigationMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final p = widget.progress.position;
    if (_ready && _follow && p != null && p != oldWidget.progress.position) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ready && _follow) {
          _map.move(_latLng(p), _map.camera.zoom);
        }
      });
    }
  }

  List<Polyline> _walkedLines() {
    final points = widget.progress.walkedPath;
    final breaks = [
      0,
      ...widget.progress.trailBreakIndices.where(
        (i) => i > 0 && i < points.length,
      ),
      points.length,
    ];
    return [
      for (var i = 0; i < breaks.length - 1; i++)
        if (breaks[i + 1] - breaks[i] >= 2)
          Polyline(
            points: points
                .sublist(breaks[i], breaks[i + 1])
                .map(_latLng)
                .toList(),
            color: const Color(0xFF1B9E77),
            strokeWidth: 6,
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.progress;
    final position = p.position;
    // With no GPS we explicitly show a waiting panel, never a fake initial location.
    if (position == null) {
      return Center(child: Text(p.message, textAlign: TextAlign.center));
    }
    final bearing = p.targetBearing;
    GeoPoint? directionTip;
    if (bearing != null) {
      final rad = bearing * math.pi / 180;
      directionTip = GeoPoint(
        position.lat + math.cos(rad) * 18 / 111195,
        position.lng +
            math.sin(rad) *
                18 /
                (111195 * math.cos(position.lat * math.pi / 180)),
      );
    }
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _latLng(position),
            initialZoom: 18,
            minZoom: 3,
            maxZoom: 19,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () => _ready = true,
            onPositionChanged: (_, hasGesture) {
              if (hasGesture && _follow) setState(() => _follow = false);
            },
            onLongPress: (_, point) => widget.onDestinationPicked?.call(
              GeoPoint(point.latitude, point.longitude),
            ),
          ),
          children: [
            TileLayer(
              tileProvider: widget.tileProvider,
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.smart_navigation',
              errorTileCallback: (_, _, _) {
                if (!_tileError) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _tileError = true);
                  });
                }
              },
            ),
            CircleLayer(
              circles: [
                CircleMarker(
                  point: _latLng(position),
                  radius: (p.accuracyMeters ?? 0).clamp(0, 200).toDouble(),
                  useRadiusInMeter: true,
                  color: Colors.blue.withValues(alpha: 0.10),
                  borderColor: Colors.blue.withValues(alpha: 0.35),
                  borderStrokeWidth: 1,
                ),
              ],
            ),
            PolylineLayer(
              polylines: [
                ..._walkedLines(),
                if (p.remainingPath.length >= 2)
                  Polyline(
                    points: p.remainingPath.map(_latLng).toList(),
                    color: const Color(0xFF1565C0),
                    strokeWidth: 5,
                  ),
                if (directionTip != null)
                  Polyline(
                    points: [_latLng(position), _latLng(directionTip)],
                    color: Colors.deepOrange,
                    strokeWidth: 4,
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                if (p.destination != null)
                  Marker(
                    point: _latLng(p.destination!),
                    width: 44,
                    height: 44,
                    child: const Tooltip(
                      message: 'Điểm đến',
                      child: Icon(
                        Icons.location_pin,
                        size: 42,
                        color: Colors.red,
                      ),
                    ),
                  ),
                Marker(
                  point: _latLng(position),
                  width: 48,
                  height: 48,
                  child: Semantics(
                    label:
                        'Vị trí GPS của bạn. Mũi tên chỉ hướng đầu điện thoại.',
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                      child: p.headingDegrees == null
                          ? const Icon(
                              Icons.my_location,
                              color: Colors.blue,
                              size: 28,
                            )
                          : Transform.rotate(
                              angle: p.headingDegrees! * math.pi / 180,
                              child: const Icon(
                                Icons.navigation,
                                color: Colors.blue,
                                size: 34,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.bottomRight,
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Text(
                    '© OpenStreetMap contributors',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ),
          ],
        ),
        Positioned(
          top: 12,
          left: 12,
          right: 72,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: DefaultTextStyle.merge(
                style: const TextStyle(fontSize: 11),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('↑ Bắc · Bản đồ luôn hướng Bắc'),
                    const Text('Xanh lá: đã đi · Xanh dương: còn lại'),
                    const Text('Mũi tên xanh: đầu điện thoại'),
                    const Text('Cam: hướng theo lối đi'),
                    if (_tileError)
                      const Text(
                        'Không tải được nền bản đồ. Kiểm tra mạng.',
                        style: TextStyle(color: Colors.orange),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 32,
          right: 12,
          child: FloatingActionButton.small(
            heroTag: null,
            tooltip: 'Theo dõi vị trí của tôi',
            onPressed: () {
              setState(() {
                _follow = true;
                _tileError = false;
              });
              if (_ready) _map.move(_latLng(position), 18);
            },
            child: Icon(_follow ? Icons.gps_fixed : Icons.gps_not_fixed),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }
}

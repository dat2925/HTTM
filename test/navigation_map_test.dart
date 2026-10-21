import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/models/geo_point.dart';
import 'package:smart_navigation/models/route_progress.dart';
import 'package:smart_navigation/widgets/navigation_map.dart';

class MemoryTiles extends TileProvider {
  final Uint8List bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(bytes);
}

void main() {
  testWidgets('no GPS never displays a fabricated location', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: NavigationMap(progress: RouteProgress())),
      ),
    );
    expect(find.text('Đang tìm vị trí GPS...'), findsOneWidget);
    expect(find.byType(FlutterMap), findsNothing);
  });
  testWidgets(
    'map shows position, heading, remaining path and attribution on narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const progress = RouteProgress(
        position: GeoPoint(21.0285, 105.8542),
        headingDegrees: 90,
        targetBearing: 45,
        accuracyMeters: 8,
        destination: GeoPoint(21.029, 105.855),
        remainingPath: [GeoPoint(21.0285, 105.8542), GeoPoint(21.029, 105.855)],
        walkedPath: [GeoPoint(21.028, 105.854), GeoPoint(21.0285, 105.8542)],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NavigationMap(
              progress: progress,
              tileProvider: MemoryTiles(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.navigation), findsOneWidget);
      expect(find.byIcon(Icons.location_pin), findsOneWidget);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      expect(find.byType(CircleLayer), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}

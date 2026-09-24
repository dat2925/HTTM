import 'package:flutter_compass/flutter_compass.dart';

/// Real device magnetometer heading (degrees, 0 = north). Unlike GPS
/// course-over-ground (`Position.heading`), this updates instantly while
/// standing still — required to tell a stationary user which way to face
/// before they have taken a single step.
class CompassService {
  Stream<double> get heading {
    final events = FlutterCompass.events;
    if (events == null) return const Stream<double>.empty();
    return events
        .where((event) => event.heading != null)
        .map((event) => event.heading!);
  }
}

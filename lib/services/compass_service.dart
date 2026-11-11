import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';

/// Direction the user is facing (degrees, 0 = north), from the device
/// magnetometer. Unlike GPS course-over-ground (`Position.heading`), this
/// updates instantly while standing still — required to tell a stationary
/// user which way to turn before they have taken a single step.
///
/// The value is the azimuth of the phone's top edge, so the phone has to be
/// held tilted with its top pointing forward (as when reading it), not fully
/// upright. flutter_compass only fills `headingForCameraMode` on iOS; on
/// Android that field is always 0, so it must not be used there.
class CompassService {
  Stream<double> get heading {
    final events = FlutterCompass.events;
    if (events == null) return const Stream<double>.empty();
    final cameraMode = defaultTargetPlatform == TargetPlatform.iOS;
    // No accuracy filter: Android reports 15/30/45 for high/medium/low sensor
    // status, and dropping everything but "high" left the heading frozen.
    return events
        .map(
          (event) => facingDegrees(
            event.heading,
            cameraMode ? event.headingForCameraMode : null,
          ),
        )
        .where((degrees) => degrees != null)
        .cast<double>();
  }

  /// Camera-axis heading when supplied, else the top-edge heading; always
  /// normalised to [0, 360). Null when neither value is usable.
  static double? facingDegrees(double? heading, double? cameraHeading) {
    final value = cameraHeading != null && cameraHeading.isFinite
        ? cameraHeading
        : heading;
    if (value == null || !value.isFinite) return null;
    return (value % 360 + 360) % 360;
  }
}

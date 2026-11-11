import 'package:flutter_compass/flutter_compass.dart';

/// Direction the user is facing (degrees, 0 = north), from the device
/// magnetometer. Unlike GPS course-over-ground (`Position.heading`), this
/// updates instantly while standing still — required to tell a stationary
/// user which way to turn before they have taken a single step.
///
/// The app is used with the back camera pointing forward (phone upright or
/// tilted), so the camera-axis heading is preferred: the plain `heading` is
/// the azimuth of the top edge and breaks down when the phone is upright.
/// `heading` remains the fallback where the platform has no camera-mode value.
class CompassService {
  Stream<double> get heading {
    final events = FlutterCompass.events;
    if (events == null) return const Stream<double>.empty();
    return events
        .where(
          (event) =>
              facingDegrees(event.heading, event.headingForCameraMode) !=
                  null &&
              (event.accuracy == null ||
                  event.accuracy! < 0 ||
                  event.accuracy! <= 25),
        )
        .map(
          (event) => facingDegrees(event.heading, event.headingForCameraMode)!,
        );
  }

  /// Camera-axis heading when available, else the top-edge heading; always
  /// normalised to [0, 360). Null when neither value is usable.
  static double? facingDegrees(double? heading, double? cameraHeading) {
    final value = cameraHeading != null && cameraHeading.isFinite
        ? cameraHeading
        : heading;
    if (value == null || !value.isFinite) return null;
    return (value % 360 + 360) % 360;
  }
}

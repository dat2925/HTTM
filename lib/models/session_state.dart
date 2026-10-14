import 'detection_result.dart';

/// State driving [StatusPanel]. [statusText] is the big headline;
/// [subStatusText] shows which stream (route vs. camera) produced the
/// current decision, so a demo audience can see both loops working.
sealed class SessionState {
  const SessionState({required this.statusText, this.subStatusText});

  final String statusText;
  final String? subStatusText;

  bool get isAlerting => this is SessionAlerting;
}

class SessionIdle extends SessionState {
  const SessionIdle({super.statusText = 'Nhấn Start AI để bắt đầu.'});
}

class SessionRunning extends SessionState {
  const SessionRunning({required super.statusText, super.subStatusText});
}

class SessionAlerting extends SessionState {
  const SessionAlerting({
    required super.statusText,
    super.subStatusText,
    required this.objectName,
    required this.danger,
  });

  final String objectName;
  final DangerLevel danger;
}

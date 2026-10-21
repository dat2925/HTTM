import 'placemark.dart';

class AssistantMessage {
  const AssistantMessage(
    this.text, {
    this.fromUser = false,
    this.proactive = false,
  });
  final String text;
  final bool fromUser;
  final bool proactive;
}

class AssistantProposal {
  const AssistantProposal({
    required this.id,
    required this.action,
    required this.expiresAt,
    this.place,
  });
  final String id;
  final String action;
  final DateTime expiresAt;
  final Placemark? place;
  factory AssistantProposal.fromJson(Map<String, dynamic> json) {
    const allowed = {
      'set_destination',
      'refresh_route',
      'cancel_navigation',
      'repeat_instruction',
      'describe_location',
    };
    final action = json['action'] as String;
    if (!allowed.contains(action) || json['requires_confirmation'] != true) {
      throw const FormatException('Invalid assistant proposal');
    }
    final place = json['place'] == null
        ? null
        : Placemark.fromJson(Map<String, dynamic>.from(json['place']));
    if (action == 'set_destination' &&
        (place == null ||
            !place.lat.isFinite ||
            !place.lng.isFinite ||
            place.lat.abs() > 90 ||
            place.lng.abs() > 180)) {
      throw const FormatException('Invalid destination proposal');
    }
    return AssistantProposal(
      id: json['id'] as String,
      action: action,
      place: place,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        ((json['expires_at'] as num) * 1000).round(),
        isUtc: true,
      ),
    );
  }
  String get label => switch (action) {
    'set_destination' => 'Đi tới ${place!.displayName}',
    'refresh_route' => 'Cập nhật tuyến đi bộ',
    'cancel_navigation' => 'Hủy dẫn đường',
    'repeat_instruction' => 'Đọc lại chỉ dẫn',
    'describe_location' => 'Đọc vị trí hiện tại',
    _ => 'Thao tác không hỗ trợ',
  };
}

class AssistantReply {
  const AssistantReply({
    required this.requestId,
    required this.text,
    required this.expiresAt,
    this.proposals = const [],
  });
  final String requestId;
  final String text;
  final DateTime expiresAt;
  final List<AssistantProposal> proposals;
  factory AssistantReply.fromJson(Map<String, dynamic> json) {
    if (json['safety'] != 'advisory_only') {
      throw const FormatException('Invalid assistant response');
    }
    return AssistantReply(
      requestId: json['request_id'] as String,
      text: (json['text'] as String).substring(
        0,
        (json['text'] as String).length.clamp(0, 800),
      ),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        ((json['expires_at'] as num) * 1000).round(),
        isUtc: true,
      ),
      proposals: (json['proposals'] as List)
          .map((p) => AssistantProposal.fromJson(Map<String, dynamic>.from(p)))
          .toList(),
    );
  }
}

class AssistantState {
  const AssistantState({
    this.paired = false,
    this.busy = false,
    this.proactive = false,
    this.error,
    this.messages = const [],
    this.proposal,
  });
  final bool paired;
  final bool busy;
  final bool proactive;
  final String? error;
  final List<AssistantMessage> messages;
  final AssistantProposal? proposal;
}

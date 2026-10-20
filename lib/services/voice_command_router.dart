enum VoiceCommandKind {
  destination,
  confirm,
  dismiss,
  location,
  cancelNavigation,
  repeat,
  refresh,
  assistant,
}

class VoiceCommand {
  const VoiceCommand(this.kind, {this.destination, this.includeImage = false});
  final VoiceCommandKind kind;
  final String? destination;
  final bool includeImage;

  /// Only established, bounded templates bypass the assistant. A question
  /// containing one of these phrases is still a question, not a navigation action.
  static VoiceCommand parse(String text) {
    final normalized = text
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[.!?,;]+$'), '')
        .trim();
    final lower = normalized.toLowerCase();
    const commands = {
      'xác nhận': VoiceCommandKind.confirm,
      'xác nhận ai': VoiceCommandKind.confirm,
      'đúng': VoiceCommandKind.confirm,
      'đúng rồi': VoiceCommandKind.confirm,
      'đồng ý': VoiceCommandKind.confirm,
      'hủy': VoiceCommandKind.dismiss,
      'không': VoiceCommandKind.dismiss,
      'không đúng': VoiceCommandKind.dismiss,
      'tôi ở đâu': VoiceCommandKind.location,
      'tôi đang ở đâu': VoiceCommandKind.location,
      'đang ở đâu': VoiceCommandKind.location,
      'dừng dẫn đường': VoiceCommandKind.cancelNavigation,
      'hủy dẫn đường': VoiceCommandKind.cancelNavigation,
      'nhắc lại': VoiceCommandKind.repeat,
      'nhắc lại hướng dẫn': VoiceCommandKind.repeat,
      'cập nhật tuyến': VoiceCommandKind.refresh,
      'cập nhật tuyến đi bộ': VoiceCommandKind.refresh,
      'tính lại đường': VoiceCommandKind.refresh,
    };
    if (commands.containsKey(lower)) return VoiceCommand(commands[lower]!);
    for (final prefix in const [
      'dẫn tôi đến',
      'dẫn tôi tới',
      'đưa tôi đến',
      'đưa tôi tới',
      'đi đến',
      'đi tới',
      'tới',
      'đến',
    ]) {
      if (lower.startsWith('$prefix ')) {
        return VoiceCommand(
          VoiceCommandKind.destination,
          destination: normalized.substring(prefix.length).trim(),
        );
      }
    }
    return VoiceCommand(
      VoiceCommandKind.assistant,
      includeImage: [
        'phân tích ảnh',
        'nhìn thấy gì',
        'phía trước có gì',
        'mô tả ảnh',
      ].any(lower.contains),
    );
  }
}

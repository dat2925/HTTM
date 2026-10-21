import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/services/voice_command_router.dart';

void main() {
  test('templates tolerate STT case, spaces and trailing punctuation', () {
    expect(
      VoiceCommand.parse(' TÔI   ĐANG Ở ĐÂU? ').kind,
      VoiceCommandKind.location,
    );
    expect(VoiceCommand.parse('Nhắc lại!').kind, VoiceCommandKind.repeat);
    expect(VoiceCommand.parse('Đi đến   Công viên.').destination, 'Công viên');
    expect(VoiceCommand.parse('xác nhận AI').kind, VoiceCommandKind.confirm);
  });
  test('phrase embedded in a question is not a local navigation action', () {
    for (final text in [
      'Bạn có biết tôi đang ở đâu và gần gì không?',
      'Tại sao phải dừng dẫn đường?',
      'đến',
      'đếnnơi',
      'hãy giải thích hướng đi hiện tại',
    ]) {
      expect(
        VoiceCommand.parse(text).kind,
        VoiceCommandKind.assistant,
        reason: text,
      );
    }
    expect(VoiceCommand.parse('Phía trước có gì?').includeImage, isTrue);
  });
}

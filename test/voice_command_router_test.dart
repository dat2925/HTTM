import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/services/voice_command_router.dart';
import 'package:smart_navigation/services/pairing_qr.dart';

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
    expect(VoiceCommand.parse('Xung quanh tôi có gì?').includeImage, isTrue);
    expect(
      VoiceCommand.parse('Theo dõi xe phía trước').monitorCategory,
      'vehicle',
    );
    expect(
      VoiceCommand.parse('Dừng theo dõi').kind,
      VoiceCommandKind.stopMonitoring,
    );
  });
  test('natural destination prefixes preserve place and reject questions', () {
    for (final prefix in [
      'tôi muốn đi đến',
      'tôi muốn đi tới',
      'tôi muốn đến',
      'tôi muốn tới',
      'tôi cần đến',
      'tôi cần tới',
      'chỉ đường đến',
      'chỉ đường tới',
      'dẫn đường đến',
      'dẫn đường tới',
      'đi ra',
      'ra',
    ]) {
      final command = VoiceCommand.parse('$prefix Công viên.');
      expect(command.kind, VoiceCommandKind.destination, reason: prefix);
      expect(command.destination, 'Công viên', reason: prefix);
      for (final question in [
        '$prefix Công viên?',
        '$prefix Công viên không.',
      ]) {
        expect(
          VoiceCommand.parse(question).kind,
          VoiceCommandKind.assistant,
          reason: question,
        );
      }
    }
    expect(VoiceCommand.parse('xác nhận').kind, VoiceCommandKind.confirm);
    expect(VoiceCommand.parse('hủy').kind, VoiceCommandKind.dismiss);
    expect(VoiceCommand.parse('không').kind, VoiceCommandKind.dismiss);
  });
  test('QR accepts enrollment only and cannot override backend or include secrets', () {
    expect(
      PairingQr.codeFrom(
        '{"type":"smart_navigation_pairing","version":1,"pairing_code":"demo-code-123456"}',
      ),
      'demo-code-123456',
    );
    expect(PairingQr.codeFrom(' demo-code-123456 '), 'demo-code-123456');
    for (final raw in [
      'https://example.com',
      '123',
      '{bad json}',
      '{"type":"smart_navigation_pairing","version":2,"pairing_code":"demo-code-123456"}',
      '{"type":"smart_navigation_pairing","version":1,"pairing_code":"demo-code-123456","server_url":"https://other.example"}',
      '{"type":"smart_navigation_pairing","version":1,"pairing_code":123456789012}',
      'a' * 4097,
    ]) {
      expect(PairingQr.codeFrom(raw), isNull);
    }
  });
}

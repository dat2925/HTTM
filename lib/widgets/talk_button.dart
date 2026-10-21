import 'package:flutter/material.dart';

import '../controllers/session_controller.dart';

class TalkButton extends StatelessWidget {
  const TalkButton({super.key, required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) => StreamBuilder<bool>(
    stream: controller.listening,
    initialData: controller.isListening,
    builder: (context, snapshot) {
      final listening = snapshot.data ?? false;
      return Semantics(
        button: true,
        label: 'Nói lệnh',
        hint: 'Nhấn giữ để nói. Kích hoạt để bắt đầu hoặc kết thúc ghi âm.',
        onTap: () =>
            listening ? controller.onTalkEnd() : controller.onTalkStart(),
        child: Listener(
          onPointerDown: (_) => controller.onTalkStart(),
          onPointerUp: (_) => controller.onTalkEnd(),
          onPointerCancel: (_) => controller.onTalkEnd(),
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            width: double.infinity,
            decoration: BoxDecoration(
              color: listening
                  ? Colors.redAccent
                  : Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Text(
              listening ? 'ĐANG NGHE...' : 'NHẤN GIỮ ĐỂ NÓI',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      );
    },
  );
}

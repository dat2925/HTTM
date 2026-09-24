import 'package:flutter/material.dart';

import '../controllers/session_controller.dart';

/// Press-and-hold talk button. Uses [Listener.onPointerDown]/[onPointerUp]
/// instead of `onLongPress`, which has a ~500ms recognition delay that would
/// clip the first word of speech and make the button feel unresponsive.
class TalkButton extends StatelessWidget {
  const TalkButton({super.key, required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => controller.onTalkStart(),
      onPointerUp: (_) => controller.onTalkEnd(),
      child: StreamBuilder<bool>(
        stream: controller.listening,
        initialData: false,
        builder: (context, snapshot) {
          final isListening = snapshot.data ?? false;
          return Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isListening
                  ? Colors.redAccent
                  : Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(24),
            ),
            alignment: Alignment.center,
            child: Text(
              isListening ? 'ĐANG NGHE...' : 'NHẤN GIỮ ĐỂ NÓI',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
        },
      ),
    );
  }
}

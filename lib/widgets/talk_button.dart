import 'package:flutter/material.dart';

import '../controllers/session_controller.dart';

/// Press-and-hold talk button. Uses [Listener.onPointerDown]/[onPointerUp]
/// instead of `onLongPress`, which has a ~500ms recognition delay that would
/// clip the first word of speech and make the button feel unresponsive.
class TalkButton extends StatefulWidget {
  const TalkButton({super.key, required this.controller});

  final SessionController controller;

  @override
  State<TalkButton> createState() => _TalkButtonState();
}

class _TalkButtonState extends State<TalkButton> {
  int? _pointer;
  SessionController get controller => widget.controller;

  void _endPointer(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    controller.onTalkEnd();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Nói lệnh dẫn đường hoặc hỏi trợ lý AI',
      hint:
          'Nhấn giữ để nói; với trình đọc màn hình, kích hoạt để bắt đầu hoặc kết thúc.',
      onTap: () => controller.isListening
          ? controller.onTalkEnd()
          : controller.onTalkStart(),
      child: Listener(
        onPointerDown: (event) {
          if (_pointer != null) return;
          _pointer = event.pointer;
          controller.onTalkStart();
        },
        onPointerUp: _endPointer,
        onPointerCancel: _endPointer,
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
      ),
    );
  }
}

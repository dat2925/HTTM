import 'package:flutter/material.dart';
import '../controllers/session_controller.dart';
import '../models/assistant_state.dart';
import '../models/session_state.dart';
import '../services/voice_command_router.dart';

/// The primary talk button's answer and confirmation live beside the map.
class AssistantPanel extends StatelessWidget {
  const AssistantPanel({
    super.key,
    required this.controller,
    required this.onOpen,
  });
  final SessionController controller;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => StreamBuilder<SessionState>(
    stream: controller.states,
    builder: (_, session) => StreamBuilder<AssistantState>(
      stream: controller.assistant.states,
      initialData: controller.assistant.state,
      builder: (_, snapshot) {
        final state = snapshot.data!;
        final replies = state.messages.where((message) => !message.fromUser);
        final latest = replies.isEmpty ? null : replies.last;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Nhấn giữ nút nói: lệnh dẫn đường hoặc hỏi trợ lý.'),
            if (controller.lastUtterance != null)
              Text(
                'Bạn: ${controller.lastUtterance}\n'
                'Xử lý: ${controller.lastCommandKind == VoiceCommandKind.assistant ? 'Trợ lý AI' : 'Hệ thống dẫn đường'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (session.data?.statusText.startsWith('Đang nghe:') ?? false)
              Text(session.data!.statusText),
            if (state.busy) ...[
              const LinearProgressIndicator(),
              const Text('Trợ lý đang trả lời...'),
            ],
            if (latest != null)
              SelectableText(
                '${latest.proactive ? 'Thông tin chủ động' : 'Trợ lý'}: ${latest.text}',
              ),
            if (state.error != null)
              Text(state.error!, style: const TextStyle(color: Colors.orange)),
            if (latest?.guidance?.evidenceSources.isNotEmpty ?? false)
              Text(
                latest!.evidenceLabel,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (state.proposal != null)
              AssistantProposalControls(
                controller: controller,
                proposal: state.proposal!,
              ),
            if (!state.paired)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Kết nối trợ lý'),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class AssistantProposalControls extends StatelessWidget {
  const AssistantProposalControls({
    super.key,
    required this.controller,
    required this.proposal,
  });
  final SessionController controller;
  final AssistantProposal proposal;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Đề xuất chưa thực hiện: ${proposal.label}'),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: controller.assistant.dismissProposal,
            child: const Text('Bỏ qua'),
          ),
          FilledButton(
            onPressed: controller.assistant.confirmProposal,
            child: const Text('Xác nhận thao tác'),
          ),
        ],
      ),
    ],
  );
}

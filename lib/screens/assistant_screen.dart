import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/session_controller.dart';
import '../models/assistant_state.dart';
import '../widgets/talk_button.dart';
import '../widgets/assistant_panel.dart';
import '../services/pairing_qr.dart';
import '../services/assistant_service.dart';
import 'pairing_qr_screen.dart';

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.controller, this.scanQr});
  final SessionController controller;
  final Future<String?> Function(BuildContext)? scanQr;
  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _input = TextEditingController();
  final _pairingCode = TextEditingController();
  bool _includeImage = false, _allowInsecure = false, _pairing = false;
  bool _showCode = false, _scanning = false;
  String? _pairingInputError;
  Future<void> _send() async {
    final message = _input.text.trim();
    if (message.isEmpty) return;
    _input.clear();
    FocusScope.of(context).unfocus();
    await widget.controller.handleUtterance(
      message,
      includeImage: _includeImage,
    );
  }

  Future<void> _pair() async {
    if (_pairing || _scanning || _pairingCode.text.trim().isEmpty) return;
    setState(() {
      _pairing = true;
      _pairingInputError = null;
    });
    final success = await widget.controller.assistant.pair(
      _pairingCode.text,
      allowInsecure: _allowInsecure,
    );
    if (mounted) {
      setState(() {
        if (success) _pairingCode.clear();
        _pairing = false;
      });
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || data?.text == null) return;
    final code = PairingQr.codeFrom(data!.text!);
    setState(() {
      // Manual input is editable even when the code is incorrect.
      _pairingCode.text = code ?? data.text!.trim();
      _pairingInputError = null;
    });
  }

  Future<void> _scan() async {
    if (_scanning || _pairing) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _scanning = true;
      _pairingInputError = null;
    });
    var borrowed = false, wasRunning = false;
    try {
      wasRunning = await widget.controller.suspendCameraForQr();
      borrowed = true;
      if (!mounted) return;
      final raw = await (widget.scanQr ?? PairingQrScreen.scan)(context);
      if (!mounted || raw == null) return;
      final code = PairingQr.codeFrom(raw);
      setState(() {
        if (code == null) {
          _pairingInputError = 'QR không hợp lệ. Mã đã nhập vẫn được giữ lại.';
        } else {
          _pairingCode.text = code;
          _pairingInputError = null;
        }
      });
    } on AssistantException catch (error) {
      if (mounted) setState(() => _pairingInputError = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _pairingInputError =
              'Chưa quét được QR. Bạn có thể nhập hoặc dán mã.',
        );
      }
    } finally {
      if (borrowed) {
        await widget.controller.resumeCameraAfterQr(
          restartPerception: wasRunning,
        );
      }
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Trợ lý AI'),
      actions: [
        IconButton(
          tooltip: 'Hội thoại mới',
          icon: const Icon(Icons.add_comment_outlined),
          onPressed: widget.controller.assistant.reset,
        ),
        IconButton(
          tooltip: 'Ngắt ghép nối trợ lý',
          icon: const Icon(Icons.link_off),
          onPressed: widget.controller.assistant.unpair,
        ),
      ],
    ),
    body: SafeArea(
      child: StreamBuilder<AssistantState>(
        stream: widget.controller.assistant.states,
        initialData: widget.controller.assistant.state,
        builder: (_, snapshot) {
          final state = snapshot.data!;
          if (!state.paired) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Nhập, dán hoặc quét QR mã ghép nối do quản trị viên cung cấp. Sau đó bấm Ghép nối.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pairingCode,
                    enabled: !_pairing && !_scanning,
                    obscureText: !_showCode,
                    autocorrect: false,
                    enableSuggestions: false,
                    onSubmitted: (_) => unawaited(_pair()),
                    decoration: InputDecoration(
                      labelText: 'Mã ghép nối thiết bị',
                      border: const OutlineInputBorder(),
                      errorText: _pairingInputError,
                      suffixIcon: IconButton(
                        tooltip: _showCode ? 'Ẩn mã' : 'Hiện mã',
                        onPressed: () => setState(() => _showCode = !_showCode),
                        icon: Icon(
                          _showCode ? Icons.visibility_off : Icons.visibility,
                        ),
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _pairing || _scanning ? null : _paste,
                        icon: const Icon(Icons.content_paste),
                        label: const Text('Dán mã'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _pairing || _scanning ? null : _scan,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: Text(
                          _scanning ? 'Đang mở camera...' : 'Quét QR',
                        ),
                      ),
                    ],
                  ),
                  if (kDebugMode)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Cho phép HTTP mạng nội bộ (debug)'),
                      subtitle: const Text(
                        'Chỉ dùng trên mạng thử nghiệm tin cậy. Bản release yêu cầu HTTPS.',
                      ),
                      value: _allowInsecure,
                      onChanged: (value) =>
                          setState(() => _allowInsecure = value ?? false),
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _pairing || _scanning ? null : _pair,
                    child: Text(_pairing ? 'Đang ghép nối...' : 'Ghép nối'),
                  ),
                  if (state.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        state.error!,
                        style: const TextStyle(color: Colors.orange),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    'Dẫn đường và cảnh báo vật cản vẫn hoạt động khi trợ lý chưa ghép nối hoặc mất mạng.',
                  ),
                ],
              ),
            );
          }
          return Column(
            children: [
              Flexible(
                flex: 2,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: Text(
                          'Trợ lý chỉ cung cấp thông tin tham khảo. Không xác nhận an toàn di chuyển. Ảnh và ngữ cảnh được gửi tới backend/OpenAI khi bạn yêu cầu.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      SwitchListTile(
                        dense: true,
                        title: const Text('Thông tin chủ động'),
                        subtitle: const Text(
                          'Chỉ khi ngữ cảnh đáng chú ý; tối thiểu 2 phút giữa các lần.',
                        ),
                        value: state.proactive,
                        onChanged: widget.controller.assistant.setProactive,
                      ),
                    ],
                  ),
                ),
              ),
              if (state.busy) const LinearProgressIndicator(),
              Expanded(
                flex: 5,
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final message in state.messages)
                      Align(
                        alignment: message.fromUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Card(
                          color: message.fromUser
                              ? Theme.of(context).colorScheme.primaryContainer
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${message.proactive ? 'Thông tin chủ động: ' : ''}${message.text}',
                                ),
                                if (message
                                        .guidance
                                        ?.evidenceSources
                                        .isNotEmpty ??
                                    false)
                                  Text(
                                    message.evidenceLabel,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (state.error != null)
                      Text(
                        state.error!,
                        style: const TextStyle(color: Colors.orange),
                      ),
                  ],
                ),
              ),
              Flexible(
                flex: 3,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      if (state.proposal != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: AssistantProposalControls(
                            controller: widget.controller,
                            proposal: state.proposal!,
                          ),
                        ),
                      CheckboxListTile(
                        dense: true,
                        title: const Text('Kèm ảnh camera cho câu hỏi này'),
                        value: _includeImage,
                        onChanged: (value) =>
                            setState(() => _includeImage = value ?? false),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _input,
                                maxLength: 1500,
                                minLines: 1,
                                maxLines: 3,
                                onSubmitted: (_) => unawaited(_send()),
                                decoration: const InputDecoration(
                                  labelText: 'Hỏi trợ lý',
                                  counterText: '',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Gửi câu hỏi',
                              icon: const Icon(Icons.send),
                              onPressed: _send,
                            ),
                          ],
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text(
                          'Lệnh quen thuộc do hệ thống dẫn đường xử lý. Câu hỏi khác được chuyển tới trợ lý AI.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      if (MediaQuery.viewInsetsOf(context).bottom == 0)
                        SizedBox(
                          height: 94,
                          child: TalkButton(controller: widget.controller),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
  @override
  void dispose() {
    _input.dispose();
    _pairingCode.dispose();
    super.dispose();
  }
}

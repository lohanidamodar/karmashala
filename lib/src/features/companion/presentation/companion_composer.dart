import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../client/companion_gateway.dart';

/// The phone's message box: what the composer is once it is reduced to the one
/// thing the protocol lets a phone do — send a prompt. No attachments, no
/// permission chips; those are desktop verbs.
class CompanionComposer extends StatefulWidget {
  const CompanionComposer({
    required this.onSend,
    this.hintText = 'Message the agent…',
    this.enabled = true,
    super.key,
  });

  /// Sends the prompt; awaited so the box can show a busy state and keep the
  /// text for retry when the host refuses.
  final Future<void> Function(String text) onSend;

  final String hintText;
  final bool enabled;

  @override
  State<CompanionComposer> createState() => _CompanionComposerState();
}

class _CompanionComposerState extends State<CompanionComposer> {
  final _input = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || !widget.enabled) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onSend(text);
      if (mounted) _input.clear();
    } catch (e) {
      // Keep the text so the user can retry once the host is back.
      messenger.showSnackBar(
        SnackBar(content: Text(e is GatewayException ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canType = widget.enabled && !_busy;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: canType,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    hintText: widget.hintText,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Send',
                onPressed: canType ? _send : null,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(AppIcons.paperPlaneRight, size: 18),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

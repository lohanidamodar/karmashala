import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../client/companion_gateway.dart';

/// The phone's message box: what the composer is once it is reduced to the one
/// thing the protocol lets a phone do — send a prompt. No attachments, no
/// permission chips; those are desktop verbs.
class CompanionComposer extends StatefulWidget {
  const CompanionComposer({
    required this.onSend,
    this.hintText = 'Message the agent…',
    this.enabled = true,
    this.controller,
    super.key,
  });

  /// Sends the prompt; awaited so the box can show a busy state and keep the
  /// text for retry when the host refuses.
  final Future<void> Function(String text) onSend;

  final String hintText;
  final bool enabled;
  final TextEditingController? controller;

  @override
  State<CompanionComposer> createState() => _CompanionComposerState();
}

class _CompanionComposerState extends State<CompanionComposer> {
  late TextEditingController _input;

  /// Held so the box can be focused again after a send. `TextInputAction.send`
  /// unfocuses on its way through `EditableText`, which closes the keyboard
  /// after every message — the phone's version of "did that go?".
  final _focus = FocusNode();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _input = widget.controller ?? TextEditingController();
    _input.addListener(_onInputChange);
  }

  void _onInputChange() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(CompanionComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _input.removeListener(_onInputChange);
      if (oldWidget.controller == null) {
        _input.dispose();
      }
      _input = widget.controller ?? TextEditingController();
      _input.addListener(_onInputChange);
    }
  }

  @override
  void dispose() {
    _input.removeListener(_onInputChange);
    _focus.dispose();
    if (widget.controller == null) _input.dispose();
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
      if (mounted) {
        _input.clear();
        // Straight into the next message, the way every other chat box
        // behaves: `TextInputAction.send` took the focus away on its way
        // through, and a keyboard that shuts itself after each turn reads as
        // the session having ended.
        _focus.requestFocus();
      }
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canType = widget.enabled && !_busy;
    final hasContent = _input.text.trim().isNotEmpty;
    final density = UiDensity.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Padding(
          padding: EdgeInsets.fromLTRB(
            density.padX,
            density.padY,
            density.padX,
            density.padY,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            padding: const EdgeInsets.only(left: 14, right: 4, top: 4, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: TextField(
                      controller: _input,
                      enabled: canType,
                      minLines: 1,
                      maxLines: 5,
                      // The keyboard's own key has to submit, and on Android
                      // the *input type* is what decides that: an IME reads
                      // `multiline` as "this field takes newlines" and draws
                      // Return instead of the action key, so `onSubmitted` is
                      // never called and the send lands as a line break —
                      // "it only types the message but don't send".
                      // `TextField` picks that type for itself for any
                      // `maxLines != 1`, so the single-line type is named
                      // here: the box still grows to [maxLines], and Enter is
                      // Send. The desktop composer answers the same problem
                      // the other way, intercepting a hardware Enter, which
                      // is a key a soft keyboard does not deliver.
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.send,
                      focusNode: _focus,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintText: widget.hintText,
                        hintStyle: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: Touch.gap),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: canType ? _send : null,
                  style: IconButton.styleFrom(
                    backgroundColor: (canType && hasContent)
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    foregroundColor: (canType && hasContent)
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                  constraints: BoxConstraints(
                    minWidth: density.minRow,
                    minHeight: density.minRow,
                  ),
                  icon: _busy
                      ? SizedBox.square(
                          dimension: density.icon,
                          child: const CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(AppIcons.paperPlaneRight, size: density.icon),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

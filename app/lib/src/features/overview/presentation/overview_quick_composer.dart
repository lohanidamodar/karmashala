import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_session/session.dart' show QueuedMessageState;
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/agent_states.dart';
import '../../sessions/application/session_input.dart' show newSessionInputId;
import '../../sessions/application/session_queue_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/presentation/queued_messages_strip.dart'
    show ordinalWord;
import '../application/overview_board.dart';
import '../application/overview_quick_message.dart';

/// **A quick message to one session**: one line, Enter sends, Shift+Enter
/// starts a new line, Esc clears. Says whether it went now or waits for the
/// turn running.
class OverviewQuickComposer extends ConsumerStatefulWidget {
  const OverviewQuickComposer({required this.card, super.key});

  final OverviewCard card;

  @override
  ConsumerState<OverviewQuickComposer> createState() =>
      _OverviewQuickComposerState();
}

class _OverviewQuickComposerState extends ConsumerState<OverviewQuickComposer> {
  final _text = TextEditingController();
  late final _focus = FocusNode(
    debugLabel: 'overview-quick-message',
    onKeyEvent: _key,
  );
  var _sending = false;
  String? _said;
  var _failed = false;

  /// The last message sent, which its status follows.
  QuickMessageSent? _sent;

  /// The key for the words in the box, kept until they go: a retry of the
  /// same words carries the same one.
  String? _sendKey;
  String? _keyedText;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_text.text.isEmpty && _said == null && _sent == null) {
        return KeyEventResult.ignored;
      }
      setState(() {
        _text.clear();
        _said = null;
        _sent = null;
      });
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _said = null;
    });
    // One key per message: a retry of the same words is the same send, which
    // the server takes once.
    if (text != _keyedText || _sendKey == null) {
      _keyedText = text;
      _sendKey = newSessionInputId();
    }
    try {
      final sent = await ref
          .read(overviewQuickMessageProvider)
          .send(widget.card.id, text, requestId: _sendKey);
      if (!mounted) return;
      _text.clear();
      _keyedText = null;
      _sendKey = null;
      setState(() {
        _failed = false;
        _said = null;
        _sent = sent;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _sent = null;
        _said = 'Not sent: ${error is StateError ? error.message : error}';
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    // Watched for the hint only: the send decides again when it goes.
    ref.watch(agentSessionStatusProvider(card.id));
    final queues = ref.read(overviewQuickMessageProvider).wouldQueue(card.id);
    final hint = switch (card.state) {
      AgentState.needsYou => 'Or reply in words…',
      AgentState.ended => 'Message to resume…',
      _ when queues => 'Message · queues until the turn ends',
      _ => 'Message…',
    };
    final said = _said;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: ValueKey('overview-composer:${card.id}'),
          controller: _text,
          focusNode: _focus,
          minLines: 1,
          maxLines: 4,
          enabled: !_sending,
          textInputAction: TextInputAction.newline,
          keyboardType: TextInputType.multiline,
          style: theme.textTheme.bodySmall,
          onChanged: (_) {
            if (_said != null) setState(() => _said = null);
          },
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            filled: true,
            fillColor: scheme.surfaceContainerLowest,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.sm,
            ),
            prefixIcon: Icon(
              AppIcons.chatCircle,
              size: density.iconSmall + Insets.xxs,
              color: scheme.onSurfaceVariant,
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: Insets.xl + Insets.xs,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.sm),
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.sm),
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
            suffixIcon: IconButton(
              key: ValueKey('overview-composer-send:${card.id}'),
              tooltip: 'Send to ${card.entry.title}',
              visualDensity: VisualDensity.compact,
              iconSize: density.icon,
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? SizedBox.square(
                      dimension: density.iconSmall,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(AppIcons.paperPlaneRight, color: scheme.primary),
            ),
          ),
        ),
        if (said != null || _sent != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs, left: Insets.xs),
            child: Semantics(
              liveRegion: true,
              child: said != null
                  ? Text(
                      said,
                      key: ValueKey('overview-composer-said:${card.id}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _failed
                            ? SemanticColors.of(context).failure
                            : scheme.onSurfaceVariant,
                      ),
                    )
                  : OverviewSentStatus(
                      key: ValueKey('overview-composer-said:${card.id}'),
                      sessionId: card.id,
                      sent: _sent!,
                    ),
            ),
          ),
      ],
    );
  }
}

/// **What became of a message**, in the server's words as its queue tells
/// them — the queue strip's own: "Sending…", "Queued (2nd)", "Delivered",
/// "Not sent". "Sent" when the server typed it in at once, or answered for
/// nothing (a pane this app runs).
class OverviewSentStatus extends ConsumerStatefulWidget {
  const OverviewSentStatus({
    required this.sessionId,
    required this.sent,
    super.key,
  });

  final String sessionId;
  final QuickMessageSent sent;

  @override
  ConsumerState<OverviewSentStatus> createState() => _OverviewSentStatusState();
}

class _OverviewSentStatusState extends ConsumerState<OverviewSentStatus> {
  /// Its row was seen in the queue: once it leaves, it went.
  var _seen = false;

  String _label() {
    final sent = widget.sent;
    final row = sent.rowId;
    if (row == null || !sent.queued) return 'Sent';
    final queue = ref.watch(sessionQueueProvider(widget.sessionId));
    final delivered = ref.watch(recentlyDeliveredProvider(widget.sessionId));
    var place = 0;
    for (final message in queue) {
      if (message.state == QueuedMessageState.queued) place++;
      if (message.id != row) continue;
      _seen = true;
      return switch (message.state) {
        QueuedMessageState.delivering => 'Sending…',
        QueuedMessageState.failed => 'Not sent',
        QueuedMessageState.delivered => 'Delivered',
        QueuedMessageState.cancelled => 'Cancelled',
        QueuedMessageState.queued => 'Queued (${ordinalWord(place)})',
      };
    }
    if (_seen || delivered.any((m) => m.id == row)) return 'Delivered';
    return 'Queued (${ordinalWord(sent.position ?? 1)})';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = _label();
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: label == 'Not sent'
            ? SemanticColors.of(context).failure
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

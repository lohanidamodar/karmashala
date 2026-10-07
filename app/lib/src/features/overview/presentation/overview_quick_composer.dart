import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/agent_states.dart';
import '../../sessions/application/session_status_providers.dart';
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
      if (_text.text.isEmpty && _said == null) return KeyEventResult.ignored;
      setState(() {
        _text.clear();
        _said = null;
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
    try {
      final outcome = await ref
          .read(overviewQuickMessageProvider)
          .send(widget.card.id, text);
      if (!mounted) return;
      _text.clear();
      setState(() {
        _failed = false;
        _said = switch (outcome) {
          QuickMessageOutcome.queued => 'Queued · goes when this turn ends',
          QuickMessageOutcome.sent => 'Sent',
        };
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _failed = true;
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
        if (said != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs, left: Insets.xs),
            child: Semantics(
              liveRegion: true,
              child: Text(
                said,
                key: ValueKey('overview-composer-said:${card.id}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: _failed
                      ? SemanticColors.of(context).failure
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// A tool call's row, its stand-in scope and its failed badge.

part of '../chat_transcript.dart';

/// Handed to what hangs under a tool row: set while it stands in for the
/// whole row — an open question card says all the row would.
class ToolRowStandIn extends InheritedWidget {
  const ToolRowStandIn({
    required this.standsIn,
    required super.child,
    super.key,
  });

  final ValueNotifier<bool> standsIn;

  static ValueNotifier<bool>? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToolRowStandIn>()?.standsIn;

  @override
  bool updateShouldNotify(ToolRowStandIn oldWidget) =>
      standsIn != oldWidget.standsIn;
}

/// A tool call, and every role this view does not name — a compaction notice,
/// or a role an importer invented, drawn as the agent's.
class _ToolMessageCard extends StatefulWidget {
  const _ToolMessageCard({
    required this.message,
    required this.onSaveNote,
    required this.resolveHostPath,
    required this.onPathTap,
    required this.detail,
  });

  final ChatMessage message;
  final VoidCallback? onSaveNote;
  final String? Function(String path)? resolveHostPath;
  final PathLinkCallback? onPathTap;
  final Widget? detail;

  @override
  State<_ToolMessageCard> createState() => _ToolMessageCardState();
}

class _ToolMessageCardState extends State<_ToolMessageCard> {
  final _standsIn = ValueNotifier(false);

  /// Keeps the detail's state as the row's frame comes and goes around it.
  final _detailKey = GlobalKey();

  @override
  void dispose() {
    _standsIn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    if (detail == null) return _framed(context, null);
    final kept = KeyedSubtree(key: _detailKey, child: detail);
    return ToolRowStandIn(
      standsIn: _standsIn,
      child: ValueListenableBuilder(
        valueListenable: _standsIn,
        builder: (context, standsIn, _) =>
            standsIn ? kept : _framed(context, kept),
      ),
    );
  }

  Widget _framed(BuildContext context, Widget? detail) {
    final message = widget.message;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failure = SemanticColors.of(context).failure;
    final activity = message.tool;
    final isToolError = activity?.isError == true;
    final accent = isToolError ? failure : scheme.tertiary;
    // A tool row's reasoning is only ever the field, never a scan of its text:
    // a tool row's text means `<thinking>` literally when it contains one.
    final thinking = message.role == 'tool' ? message.thinking?.trim() : null;
    final eyebrow =
        activity?.name ??
        switch (message.role) {
          'tool' => 'Tool',
          kCompactionNoticeRole => 'Compacted',
          _ => 'Agent',
        };
    final shown = toolDisplayName(eyebrow);

    return TranscriptTurnFrame(
      fill: theme.brightness == Brightness.dark
          ? scheme.surfaceContainerLowest
          : scheme.surfaceContainerLow,
      edge: isToolError ? failure : scheme.outlineVariant,
      clip: true,
      // Tighter vertically than the other roles: a tool row is the most
      // repeated thing in a transcript, so 4px multiplies by every call.
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // An MCP name is wider than a narrow pane; it gives way first.
          _MessageHeader(
            icon: _toolIcon(activity?.name),
            label: shown,
            fullLabel: activity == null ? null : eyebrow,
            color: accent,
            badge: !isCommandCall(message)
                ? (isToolError ? _FailedBadge(color: failure) : null)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isToolError) ...[
                        _FailedBadge(color: failure),
                        const SizedBox(width: Insets.xs),
                      ],
                      _CommandTime(
                        message: message,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
            actions: _messageActions(
              widget.onSaveNote,
              activity?.output ?? message.text,
            ),
          ),
          const SizedBox(height: Insets.xs),
          if (thinking != null && thinking.isNotEmpty) ...[
            ThinkingAccordion(thinking: thinking),
            const SizedBox(height: Insets.xs),
          ],
          if (activity != null)
            ToolActivityBody(
              activity: activity,
              resolveHostPath: widget.resolveHostPath,
              onPathTap: widget.onPathTap,
            )
          else
            Text(message.text, style: MonoStyles.label.copyWith(height: 1.35)),
          if (message.detail case final folded?)
            _SessionNote(text: folded, label: 'Summary'),
          ?detail,
        ],
      ),
    );
  }
}

class _FailedBadge extends StatelessWidget {
  const _FailedBadge({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        'FAILED',
        // The theme's smallest label rather than a 9pt literal, which ignores
        // a reader who scaled text up.
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}

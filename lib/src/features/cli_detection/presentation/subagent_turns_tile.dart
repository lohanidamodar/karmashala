import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../sessions/presentation/markdown_message.dart';
import '../../sessions/presentation/tool_activity_row.dart';
import '../application/subagent_providers.dart';
import 'package:agent_cli/read.dart';

/// How deep the rendering nests before it stops offering to go further. The cap
/// exists because an index pointing back at an ancestor would nest for ever.
const int kMaxSubagentNesting = 4;

/// What a delegated agent did, hung under the `Task` call that spawned it.
/// Collapsed by default and unread while collapsed — a transcript can be huge.
class SubagentTurnsTile extends ConsumerStatefulWidget {
  const SubagentTurnsTile({
    required this.reference,
    this.resolveHostPath,
    this.nesting = 0,
    super.key,
  });

  final SubagentRef reference;

  /// Passed straight through to the delegate's own tool rows: a screenshot it
  /// took is on the same machine as one the parent took.
  final String? Function(String path)? resolveHostPath;

  /// How many delegates deep this row already is in the *rendering*.
  final int nesting;

  @override
  ConsumerState<SubagentTurnsTile> createState() => _SubagentTurnsTileState();
}

class _SubagentTurnsTileState extends ConsumerState<SubagentTurnsTile> {
  bool _expanded = false;

  /// Whether the transcript has ever been asked for. Separate from [_expanded]
  /// so collapsing does not re-read the file on the next open.
  bool _read = false;

  void _toggle() => setState(() {
    _expanded = !_expanded;
    _read = _read || _expanded;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final turns = _read
        ? ref.watch(subagentTurnsProvider(widget.reference.filePath))
        : const AsyncValue<List<TranscriptMessage>>.loading();

    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SubagentHeader(
            reference: widget.reference,
            expanded: _expanded,
            // Null until it has been read: inventing a count would mean
            // reading every delegate to print a number nobody asked for.
            turnCount: _read ? turns.value?.length : null,
            onToggle: _toggle,
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: Insets.sm),
              child: DecoratedBox(
                // One rule down the side, so a delegate's turns read as
                // subordinate to the call rather than as more conversation.
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: Insets.sm),
                  child: turns.when(
                    loading: () => _Note('Reading the subagent…'),
                    error: (error, _) => _Note('$error'),
                    data: (messages) => messages.isEmpty
                        ? _Note('No turns recorded for this subagent.')
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final message in messages)
                                _SubagentTurn(
                                  message: message,
                                  resolveHostPath: widget.resolveHostPath,
                                  nesting: widget.nesting,
                                ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The row itself: what the delegate was asked to do, and enough about it to
/// decide whether to open it.
class _SubagentHeader extends StatelessWidget {
  const _SubagentHeader({
    required this.reference,
    required this.expanded,
    required this.turnCount,
    required this.onToggle,
  });

  final SubagentRef reference;
  final bool expanded;
  final int? turnCount;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = reference.description.isEmpty
        ? 'Subagent'
        : reference.description;
    return Tooltip(
      message: expanded
          ? 'Hide what this subagent did'
          : 'Show what this subagent did',
      child: TextButton(
        onPressed: onToggle,
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          minimumSize: const Size(0, Chrome.row),
          foregroundColor: scheme.onSurfaceVariant,
          alignment: Alignment.centerLeft,
        ),
        child: Row(
          children: [
            Icon(
              expanded ? AppIcons.caretDown : AppIcons.caretRight,
              size: Chrome.iconSmall,
            ),
            const SizedBox(width: Insets.xs),
            Icon(AppIcons.robot, size: Chrome.iconSmall, color: scheme.tertiary),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: Insets.sm),
            // The agent it ran as, in the ledger hand: it is a name from a
            // registry, like an id or a path.
            Text(
              reference.agentType.isEmpty ? 'subagent' : reference.agentType,
              style: MonoStyles.small.copyWith(color: scheme.onSurfaceVariant),
            ),
            // Only when it is not the ordinary case. At depth 2 a description
            // reads like a sibling of the row above it, and it is not.
            if (reference.spawnDepth > 1) ...[
              const SizedBox(width: Insets.sm),
              Text(
                'depth ${reference.spawnDepth}',
                style: MonoStyles.small.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (turnCount != null) ...[
              const SizedBox(width: Insets.sm),
              Text(
                '$turnCount turn${turnCount == 1 ? '' : 's'}',
                style: MonoStyles.small.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One turn of a delegate's transcript. Leaner than the parent's row on purpose:
/// a fan-out of ten would add hundreds of icon buttons to the tab order.
class _SubagentTurn extends StatelessWidget {
  const _SubagentTurn({
    required this.message,
    required this.nesting,
    this.resolveHostPath,
  });

  final TranscriptMessage message;
  final int nesting;
  final String? Function(String path)? resolveHostPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (String gutter, Color color, String label) = switch (message.role) {
      'user' => ('›', scheme.primary, 'Task'),
      'tool' => ('⏺', scheme.tertiary, 'Tool'),
      'error' => ('✗', scheme.error, 'Error'),
      _ => ('●', scheme.onSurface, 'Agent'),
    };
    final activity = message.tool;
    final reference = message.subagent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: Chrome.icon,
            child: Text(
              gutter,
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (activity?.name ?? label).toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                if (activity != null)
                  ToolActivityBody(
                    activity: activity,
                    resolveHostPath: resolveHostPath,
                  )
                else
                  MarkdownMessage(message.text),
                // A delegate that delegated. The cap is the guard against an
                // index that points back at an ancestor.
                if (reference != null && nesting + 1 < kMaxSubagentNesting)
                  SubagentTurnsTile(
                    reference: reference,
                    resolveHostPath: resolveHostPath,
                    nesting: nesting + 1,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A one-line aside where turns would be — reading, empty, or unreadable.
class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

part of '../chat_transcript.dart';

/// The agent that speaks next, over the first agent row of its turn.
class _AgentByline extends StatelessWidget {
  const _AgentByline({required this.name, this.agentId});

  final String name;
  final String? agentId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return SelectionContainer.disabled(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (agentId case final id?) ...[
            AgentLogo(agentId: id, size: Chrome.iconSmall, color: muted),
            const SizedBox(width: Insets.xs),
          ],
          Flexible(
            child: Text(
              name,
              key: const ValueKey('agent-byline'),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where another agent took the session over: a rule across the column,
/// "Continued with" and the agent, and — expanded — what it was handed.
class _AgentSwitchDivider extends StatefulWidget {
  const _AgentSwitchDivider({required this.message});

  final ChatMessage message;

  @override
  State<_AgentSwitchDivider> createState() => _AgentSwitchDividerState();
}

class _AgentSwitchDividerState extends State<_AgentSwitchDivider> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final message = widget.message;
    final carried = message.text.trim();
    final name = message.agentName ?? 'another agent';
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.agentId case final id?) ...[
          AgentLogo(agentId: id, size: Chrome.iconSmall, color: muted),
          const SizedBox(width: Insets.xs),
        ],
        Flexible(
          child: Text(
            'Continued with $name',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(color: muted),
          ),
        ),
        if (carried.isNotEmpty) ...[
          const SizedBox(width: Insets.xs),
          Icon(
            _open ? AppIcons.caretUp : AppIcons.caretDown,
            size: Chrome.iconSmall,
            color: muted,
          ),
        ],
      ],
    );
    return SelectionContainer.disabled(
      child: Column(
        key: const ValueKey('agent-switch-divider'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Divider()),
              Flexible(
                flex: 3,
                child: Semantics(
                  button: carried.isNotEmpty,
                  label: carried.isEmpty
                      ? null
                      : _open
                      ? 'Hide what $name was handed'
                      : 'Show what $name was handed',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    onTap: carried.isEmpty
                        ? null
                        : () => setState(() => _open = !_open),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.sm,
                        vertical: Insets.xs,
                      ),
                      child: label,
                    ),
                  ),
                ),
              ),
              const Expanded(child: Divider()),
            ],
          ),
          if (_open && carried.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: TranscriptTurnFrame(
                child: SelectionArea(
                  child: Text(
                    carried,
                    key: const ValueKey('agent-switch-packet'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';
import '../application/bot_providers.dart';

/// Why the switcher will not move now.
const kBotAgentTurnRunning = 'A turn is running: wait for it to end.';

/// What a pick in the menu asks for: null is "Default agent".
final class _Pick {
  const _Pick(this.agentId);

  final String? agentId;
}

/// The name [state]'s agent goes by, or null when none is known.
String? botAgentName(BotState state) {
  for (final agent in state.agents) {
    if (agent.agentId == state.agentId) return agent.name;
  }
  return null;
}

/// **The header's agent switcher**: the agents with a chat form on the server
/// and "Default agent". One call switches and saves. Disabled mid-turn, and
/// the reason is told rather than left to guess.
class BotAgentSwitcher extends ConsumerStatefulWidget {
  const BotAgentSwitcher({super.key});

  @override
  ConsumerState<BotAgentSwitcher> createState() => _BotAgentSwitcherState();
}

class _BotAgentSwitcherState extends ConsumerState<BotAgentSwitcher> {
  var _busy = false;

  Future<void> _set(String? agentId) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      await ref.read(botActionsProvider).setAgent(agentId);
    } on DataRefused catch (refusal) {
      messenger?.showSnackBar(SnackBar(content: Text(refusal.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(BuildContext anchor, BotState state) async {
    final picked = await showDesktopMenuUnder<_Pick>(anchor, [
      DesktopMenuItem(
        value: const _Pick(null),
        label: 'Default agent',
        icon: AppIcons.robot,
        selected: state.agentSetting == null,
      ),
      for (final agent in state.agents)
        DesktopMenuItem(
          value: _Pick(agent.agentId),
          label: agent.name,
          icon: AppIcons.robot,
          selected: state.agentSetting == agent.agentId,
        ),
    ]);
    if (picked != null && picked.agentId != state.agentSetting) {
      await _set(picked.agentId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(botStateProvider);
    if (state == null || state.agents.isEmpty) return const SizedBox.shrink();
    final running = ref.watch(botTurnRunningProvider);
    final mayManage = ref.watch(
      capabilitiesProvider.select((c) => c.manageBot),
    );
    final reason = !mayManage
        ? kStartNotGranted
        : running
        ? kBotAgentTurnRunning
        : null;
    final name = botAgentName(state) ?? 'No agent';
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final color = reason == null
        ? scheme.onSurface
        : scheme.onSurfaceVariant.withValues(
            alpha: StateLayers.dimmedOpacity * 2,
          );
    return Tooltip(
      message: reason ?? 'Agent: $name',
      child: Semantics(
        button: true,
        enabled: reason == null && !_busy,
        label: 'Agent: $name',
        hint: reason ?? 'Switch the agent the bot runs on',
        excludeSemantics: true,
        child: Builder(
          builder: (anchor) => InkWell(
            key: const ValueKey('bot-agent-switcher'),
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: _busy
                ? null
                : reason == null
                ? () => _open(anchor, state)
                // A phone has no hover to read the tooltip with.
                : () => ScaffoldMessenger.maybeOf(
                    context,
                  )?.showSnackBar(SnackBar(content: Text(reason))),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: density.isTouch ? density.minRow : Chrome.control,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: color,
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.xs),
                    Icon(
                      AppIcons.caretDown,
                      size: Chrome.iconSmall,
                      color: color,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

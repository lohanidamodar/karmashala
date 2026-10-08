import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/fact_list.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../explorer/presentation/more_menu.dart' show kMoreMenuValue;
import '../../explorer/presentation/session_row_menu.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../automations/presentation/session_origin_label.dart';
import '../../sessions/application/acp_session_providers.dart';
import '../../sessions/application/session_active_model_providers.dart';
import '../../sessions/application/session_agent_providers.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/presentation/delivery_strip.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../../sessions/presentation/model_chip.dart';
import '../../sessions/presentation/operator_chip.dart';
import '../../sessions/presentation/permission_mode_chip.dart';
import '../../sessions/presentation/session_environment_mark.dart';
import '../../sessions/presentation/session_mode_picker.dart';
import '../../sessions/presentation/session_repositories_bar.dart';
import '../../sessions/presentation/session_stats_dialog.dart';
import '../../settings/presentation/settings_row.dart'
    show SettingsCompactSwitch;
import '../../terminal/application/system_terminal_providers.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart';
import 'overview_card_parts.dart';
import 'overview_session_parts.dart';

/// **Everything about one session, as a list** (owner, 2026-10-08: the
/// cloud of chips "looks unorganized"): one row per fact, its value at the
/// end, under small group headings — Status, Agent, Code, Where, Session.
/// The pickers are the bar's own widgets, so a choice made here is the one
/// the session's tab shows. What the status strip folds into +N opens this,
/// and so does the phone's **Session ▾**.
///
/// [card] is the dashboard's; without one the board's card for [sessionId]
/// is used, when the board has it.
class SessionFactList extends ConsumerWidget {
  const SessionFactList({required this.sessionId, this.card, super.key});

  final String sessionId;
  final OverviewCard? card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card =
        this.card ??
        overviewCardOf(ref.watch(overviewBoardProvider), sessionId);
    final native = card == null || card.entry.native != null;
    final directory = card?.entry.directory;
    final branch = directory == null
        ? null
        : ref.watch(overviewKnownBranchProvider(directory));
    final repositories =
        native && ref.watch(sessionRepositoriesProvider(sessionId)).isNotEmpty;
    final place = card == null ? null : watchOverviewPlace(ref, card);
    final muted = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    Text plain(String text) => Text(text, style: muted);
    return SingleChildScrollView(
      key: const ValueKey('session-fact-list'),
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FactListHeader('Status'),
          if (card != null)
            FactRow(
              key: const ValueKey('session-list:state'),
              icon: AppIcons.clock,
              label: 'State',
              value: OverviewStatePill(card: card),
            ),
          FactRow(
            key: const ValueKey('session-list:usage'),
            icon: AppIcons.chartBar,
            label: 'Usage',
            value: OverviewUsageLine(sessionId: sessionId),
          ),
          const FactListHeader('Agent'),
          FactRow(
            key: const ValueKey('session-list:model'),
            icon: AppIcons.robot,
            label: 'Model',
            value: SessionModelValue(sessionId: sessionId, native: native),
          ),
          if (native) ...[
            FactRow(
              key: const ValueKey('session-list:permission'),
              icon: AppIcons.shield,
              label: 'Permission',
              value: PermissionModeChip(sessionId: sessionId),
            ),
            FactRow(
              key: const ValueKey('session-list:mode'),
              icon: AppIcons.slidersHorizontal,
              label: 'Agent mode',
              value: SessionModePicker(sessionId: sessionId, leadingGap: false),
            ),
          ],
          _AgentRow(sessionId: sessionId, card: card),
          if (native) _OperateRow(sessionId: sessionId),
          if (branch != null || repositories) ...[
            const FactListHeader('Code'),
            if (branch != null)
              FactRow(
                key: const ValueKey('session-list:branch'),
                icon: AppIcons.gitBranch,
                label: 'Branch',
                value: plain(branch),
              ),
            if (repositories) ...[
              SessionRepositoryRows(sessionId: sessionId),
              Padding(
                key: const ValueKey('session-list:delivery'),
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.lg,
                  vertical: Insets.xs,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: DeliveryStrip(
                    sessionId: sessionId,
                    hostedOnTerminal: true,
                    folded: true,
                  ),
                ),
              ),
            ],
          ],
          const FactListHeader('Where'),
          FactRow(
            key: const ValueKey('session-list:place'),
            icon: AppIcons.folder,
            label: 'Runs in',
            value: place == null
                ? SessionEnvironmentMark(sessionId: sessionId)
                : place.isEmpty
                ? null
                : plain(place),
          ),
          FactRow(
            key: const ValueKey('session-list:origin'),
            icon: AppIcons.lightning,
            label: 'Origin',
            value: SessionOriginLabel(sessionId: sessionId),
          ),
          if (native) ...[
            const FactListHeader('Session'),
            _SessionActionRows(sessionId: sessionId),
          ],
        ],
      ),
    );
  }
}

/// A fact on the status strip that is not a picker: a glyph and its words,
/// named whole on hover.
class SessionStripFact extends StatelessWidget {
  const SessionStripFact({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.leading,
    super.key,
  });

  final IconData icon;
  final Widget? leading;
  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        excludeSemantics: true,
        child: TouchTarget(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              leading ?? Icon(icon, size: Chrome.iconSmall, color: muted),
              const SizedBox(width: Insets.xs),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The model: its picker where the session has one to set, else what its
/// agent says it runs, as a fact — on the strip with its glyph, in a list
/// [bare]. Nothing until either is known.
class SessionModelValue extends ConsumerWidget {
  const SessionModelValue({
    required this.sessionId,
    required this.native,
    this.short = false,
    this.bare = true,
    this.maxLabelWidth = 160,
    super.key,
  });

  final String sessionId;
  final bool native;
  final bool short;
  final bool bare;

  /// The most of the model's name the picker shows before it ends.
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (native) {
      ref.watchSession(sessionId);
      // The bar's own test for a session with agent controls.
      final controls =
          ref.watch(isAcpSessionProvider(sessionId)) ||
          ref.read(sessionLauncherProvider).effectivePermissionFor(sessionId) !=
              null;
      if (controls) {
        return SessionModelChip(
          sessionId: sessionId,
          short: short,
          maxLabelWidth: maxLabelWidth,
        );
      }
    }
    final model = ref.watch(sessionActiveModelProvider(sessionId))?.label;
    if (model == null) return const SizedBox.shrink();
    if (bare) {
      final theme = Theme.of(context);
      return Text(
        model,
        key: const ValueKey('overview-peek-model'),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return SessionStripFact(
      key: const ValueKey('overview-peek-model'),
      icon: AppIcons.robot,
      label: model,
      tooltip: 'Model: $model',
    );
  }
}

/// The agent [sessionId] runs, while nothing else on screen names it — the
/// composer's switch does, wherever the server can switch agents — else
/// null.
String? watchSessionAgentShown(
  WidgetRef ref,
  String sessionId,
  OverviewCard? card,
) {
  final composerSwitches =
      (card == null || card.entry.native != null) &&
      ref.watch(capabilitiesProvider.select((c) => c.switchAgent));
  if (composerSwitches) return null;
  return card != null
      ? ref.watch(overviewFactsProvider).agentOf(card.entry)
      : ref.watch(sessionAgentIdProvider(sessionId));
}

class _AgentRow extends ConsumerWidget {
  const _AgentRow({required this.sessionId, required this.card});

  final String sessionId;
  final OverviewCard? card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agentId = watchSessionAgentShown(ref, sessionId, card);
    if (agentId == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return FactRow(
      key: const ValueKey('session-list:agent'),
      icon: AppIcons.robot,
      leading: AgentLogo(agentId: agentId, size: Chrome.icon),
      label: 'Agent',
      value: Text(
        ref.watch(agentRegistryProvider).displayNameFor(agentId),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// **Operate Karmashala**, once, as a switch: on, the agent's tools that act
/// run for it. Turning it on asks first.
class _OperateRow extends ConsumerWidget {
  const _OperateRow({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watchSession(sessionId);
    final row = ref.read(sessionsDataProvider).getById(sessionId);
    if (row == null) return const SizedBox.shrink();
    final on = row.operatorGranted;
    void set(bool granted) =>
        setOperatorGrant(context, ref, sessionId, granted: granted);
    return Tooltip(
      message: on
          ? 'This agent may operate Karmashala: start, send to and end '
                'sessions, run terminals, restore checkpoints, drive devices '
                'and builds.'
          : 'This agent reads Karmashala but cannot act on it — or start a '
                'message with /operator.',
      child: FactRow(
        key: const ValueKey('session-list:operator'),
        icon: on ? AppIcons.robot : AppIcons.shield,
        label: 'Operate Karmashala',
        onTap: () => set(!on),
        value: SettingsCompactSwitch(
          child: Switch(value: on, onChanged: set),
        ),
      ),
    );
  }
}

/// The session's verbs as labelled rows: the session menu every other place
/// has ([sessionMenuItems]), in its order and words, then the stats.
class _SessionActionRows extends ConsumerWidget {
  const _SessionActionRows({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // What the menu offers moves with the row, its process, its resume and
    // the server's offer.
    ref.watchSession(sessionId);
    sessionHasLiveProcess(ref, sessionId);
    ref.watch(sessionsStartingProvider.select((s) => s.contains(sessionId)));
    ref.watch(capabilitiesProvider);
    final terminals =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];
    final session = ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in sessionMenuItems(ref, session, terminals: terminals))
          if (item case final DesktopMenuItem<String> verb)
            Builder(
              builder: (row) => FactRow(
                key: ValueKey('session-list:${verb.value}'),
                icon: verb.icon,
                label: verb.label,
                destructive: verb.destructive,
                enabled: verb.enabled,
                chevron: verb.value == kMoreMenuValue,
                onTap: () => runNativeSessionMenuAction(
                  row,
                  ref,
                  session,
                  verb.value!,
                  terminals: terminals,
                ),
              ),
            ),
        FactRow(
          key: const ValueKey('session-list:stats'),
          icon: AppIcons.chartBar,
          label: 'Context and stats',
          value: SessionStatsButton(sessionId: sessionId),
        ),
      ],
    );
  }
}

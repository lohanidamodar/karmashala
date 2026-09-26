import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/environments/application/environment_providers.dart';
import '../../features/explorer/presentation/environment_rows.dart';
import '../../features/git/application/changes_providers.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/sessions/application/delivery_providers.dart';
import '../../features/sessions/application/session_status_providers.dart';
import '../../features/settings/presentation/settings_catalog.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_actions.dart';
import 'side_panel_state.dart';
import 'status_bar_items.dart';
import 'status_bar_layout.dart';
import 'workbench_tabs.dart';

/// The window's bottom rule: where you are on the left, what is live in the
/// middle, the panel toggle on the right. Everything on it is about the
/// **window**, and each item watches only its own value, so one change redraws
/// one item. What gives way when it narrows is [statusBarPlan]'s to decide.
class ShellStatusBar extends StatelessWidget {
  const ShellStatusBar({super.key});

  /// Builds of this row's own items, counted so a cost test can prove that a
  /// per-session change — a model, a quota — does not reach this row at all.
  @visibleForTesting
  static int get debugItemBuildCount => StatusBarItem.debugBuildCount;
  @visibleForTesting
  static set debugItemBuildCount(int value) =>
      StatusBarItem.debugBuildCount = value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(
      letterSpacing: 0,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
    );

    return Container(
      // Scaled with the text, or the labels would clip at 125%+.
      height: Chrome.statusBarOf(context),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: DefaultTextStyle.merge(
        style: style,
        // Planned on the bar's whole width, so a breakpoint means the window.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final plan = statusBarPlan(
              constraints.maxWidth,
              MediaQuery.textScalerOf(context),
            );
            Widget slot(StatusBarSlot slot) =>
                _SlotItem(slot: slot, fit: plan.fitOf(slot));
            final overflowed = plan.overflowed;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
              child: Row(
                children: [
                  // Context shares what the state group leaves, and its two names
                  // are the only labels on the bar that end rather than push.
                  Expanded(
                    child: Row(
                      children: [
                        slot(StatusBarSlot.environment),
                        Flexible(child: slot(StatusBarSlot.repository)),
                        Flexible(child: slot(StatusBarSlot.branch)),
                      ],
                    ),
                  ),
                  const StatusBarDivider(),
                  StatusBarGroup(
                    children: [
                      slot(StatusBarSlot.agents),
                      slot(StatusBarSlot.attention),
                      slot(StatusBarSlot.background),
                      slot(StatusBarSlot.tabs),
                      if (overflowed.isNotEmpty)
                        Consumer(
                          builder: (context, ref, _) => StatusBarOverflow(
                            entries: () => [
                              for (final slot in overflowed)
                                if (_describe(slot, context, ref, ref.read)
                                    case final status?)
                                  status.entry,
                            ],
                          ),
                        ),
                    ],
                  ),
                  const StatusBarDivider(),
                  slot(StatusBarSlot.panel),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One slot, watching only what [_describe] reads for it.
class _SlotItem extends ConsumerWidget {
  const _SlotItem({required this.slot, required this.fit});

  final StatusBarSlot slot;
  final StatusBarFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (fit == StatusBarFit.overflow) return const SizedBox.shrink();
    final status = _describe(slot, context, ref, ref.watch);
    return status?.item(fit) ?? const SizedBox.shrink();
  }
}

/// `ref.watch` on the bar, `ref.read` in the overflow menu: one description of
/// each item, so the menu can never say something the bar would not.
typedef _Read = T Function<T>(ProviderListenable<T> provider);

/// The environment the selected checkout lives in, or null with none selected.
final statusBarEnvironmentProvider =
    Provider.autoDispose<ExecutionEnvironment?>((ref) {
      final id = ref.watch(
        selectedRepositoryProvider.select((repo) => repo?.environmentId),
      );
      if (id == null) return null;
      return ref.read(executionEnvironmentDaoProvider).getById(id);
    });

/// What one item says and does, before it is fitted to the room it has.
class _Status {
  const _Status({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.compactLabel,
    this.glyph,
    this.richTooltip,
    this.trailing,
    this.onPressed,
    this.tone = StatusBarTone.neutral,
    this.flexible = false,
    this.enabled = true,
  });

  final IconData icon;
  final Widget? glyph;
  final String label;

  /// The count a compact item keeps; null leaves it a bare glyph.
  final String? compactLabel;
  final String tooltip;
  final InlineSpan? richTooltip;
  final Widget? trailing;
  final VoidCallback? onPressed;
  final StatusBarTone tone;
  final bool flexible;
  final bool enabled;

  StatusBarItem item(StatusBarFit fit) {
    final full = fit == StatusBarFit.full;
    return StatusBarItem(
      icon: icon,
      glyph: glyph,
      label: full ? label : compactLabel,
      tooltip: tooltip,
      richTooltip: richTooltip,
      trailing: full ? trailing : null,
      onPressed: onPressed,
      tone: tone,
      flexible: flexible,
      enabled: enabled,
    );
  }

  StatusBarOverflowEntry get entry =>
      StatusBarOverflowEntry(icon: icon, label: label, onPressed: onPressed);
}

String _plural(int count, String one, [String? many]) =>
    '$count ${count == 1 ? one : many ?? '${one}s'}';

/// The tail of a tooltip for an item that opens a side panel surface.
String _panelAction(bool room, String action) =>
    room ? 'Click to $action.' : '$kSidePanelNoRoom.';

/// Opens [surface], and leaves it open when it already is: the status bar
/// reports, so a second click must not close what the first one showed.
void _reveal(WidgetRef ref, SidePanelSurface surface) {
  if (ref.read(sidePanelProvider) == surface) return;
  ref.read(sidePanelProvider.notifier).select(surface);
}

_Status? _describe(
  StatusBarSlot slot,
  BuildContext context,
  WidgetRef ref,
  _Read read,
) => switch (slot) {
  StatusBarSlot.environment => _environment(ref, read),
  StatusBarSlot.repository => _repository(ref, read),
  StatusBarSlot.branch => _branch(ref, read),
  StatusBarSlot.agents => _agents(read),
  StatusBarSlot.attention => _attention(ref, read),
  StatusBarSlot.background => _background(context, ref, read),
  StatusBarSlot.tabs => _tabs(read),
  StatusBarSlot.panel => _panel(ref, read),
};

_Status? _environment(WidgetRef ref, _Read read) {
  final env = read(statusBarEnvironmentProvider);
  if (env == null) return null;
  final kind = switch (env.kind) {
    EnvironmentKind.wsl => 'WSL',
    EnvironmentKind.ssh => 'SSH',
    EnvironmentKind.windowsNative ||
    EnvironmentKind.localPosix => 'this machine',
  };
  return _Status(
    icon: environmentGlyph(env.kind),
    label: env.name,
    tooltip:
        'Environment ${env.name} ($kind). Click to open Environments settings.',
    onPressed: () =>
        openSettingsTab(ref, section: SettingsSectionId.environments),
  );
}

_Status _repository(WidgetRef ref, _Read read) {
  final repo = read(selectedRepositoryProvider);
  if (repo == null) {
    return const _Status(
      icon: AppIcons.bookBookmark,
      label: 'No repository selected',
      tooltip: 'No repository selected. Pick one in the Explorer.',
      flexible: true,
    );
  }
  final room = read(sidePanelRoomProvider);
  final action = _panelAction(room, 'open the Repository panel');
  return _Status(
    icon: AppIcons.bookBookmark,
    label: repo.name,
    tooltip: 'Repository ${repo.name}, ${repo.path.path}. $action',
    // The path in the ledger hand, the only place this bar spells one.
    richTooltip: TextSpan(
      children: [
        TextSpan(text: 'Repository ${repo.name}\n'),
        TextSpan(text: repo.path.path, style: MonoStyles.small),
        TextSpan(text: '\n$action'),
      ],
    ),
    flexible: true,
    onPressed: room ? () => _reveal(ref, SidePanelSurface.repository) : null,
  );
}

_Status? _branch(WidgetRef ref, _Read read) {
  final repositoryId = read(
    selectedRepositoryProvider.select((repo) => repo?.id),
  );
  if (repositoryId == null) return null;
  final branch = switch (read(currentBranchProvider)) {
    AsyncData(:final value) => value ?? 'detached',
    AsyncError() => 'no git',
    _ => '…',
  };
  // The reading the Explorer's rows already share for this checkout; a refresh
  // keeps the last numbers rather than blinking them away.
  final (dirty, unpushed) = read(
    repositoryDeliveryProvider(
      repositoryId,
    ).select((d) => (d.value?.dirtyFiles, d.value?.unpushed)),
  );
  final room = read(sidePanelRoomProvider);
  final facts = [
    if (dirty != null)
      dirty == 0 ? 'no changes' : _plural(dirty, 'changed file'),
    if (unpushed != null && unpushed > 0)
      '${_plural(unpushed, 'commit')} not pushed',
  ];
  final hasTrailing = (dirty ?? 0) > 0 || (unpushed ?? 0) > 0;
  return _Status(
    icon: AppIcons.gitBranch,
    label: branch,
    tooltip:
        'Branch $branch${facts.isEmpty ? '' : ' — ${facts.join(', ')}'}. '
        '${_panelAction(room, 'open Changes')}',
    trailing: hasTrailing
        ? _BranchCounts(dirty: dirty ?? 0, unpushed: unpushed ?? 0)
        : null,
    flexible: true,
    onPressed: room ? () => _reveal(ref, SidePanelSurface.changes) : null,
  );
}

/// A branch's dirty-file and unpushed-commit counts, each only when non-zero.
class _BranchCounts extends StatelessWidget {
  const _BranchCounts({required this.dirty, required this.unpushed});

  final int dirty;
  final int unpushed;

  @override
  Widget build(BuildContext context) {
    const figures = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dirty > 0) ...[
          const Icon(AppIcons.pencilSimple),
          const SizedBox(width: Insets.hair),
          Text('$dirty', style: figures),
        ],
        if (dirty > 0 && unpushed > 0) const SizedBox(width: Insets.xs),
        if (unpushed > 0) ...[
          const Icon(AppIcons.arrowUp),
          const SizedBox(width: Insets.hair),
          Text('$unpushed', style: figures),
        ],
      ],
    );
  }
}

_Status? _agents(_Read read) {
  // Joined so the list is compared by value: a tab re-ordering is not news.
  final joined = read(
    terminalSessionsControllerProvider.select(
      (s) => [for (final tab in s.tabs) ...tab.layout.panes].join('\n'),
    ),
  );
  if (joined.isEmpty) return null;
  var working = 0;
  var failed = 0;
  for (final paneId in joined.split('\n')) {
    switch (read(paneAgentActivityProvider(paneId))) {
      case AgentActivityStatus.working:
        working++;
      case AgentActivityStatus.failed:
        failed++;
      case _:
        break;
    }
  }
  if (working == 0 && failed == 0) return null;
  final status = failed > 0
      ? AgentActivityStatus.failed
      : AgentActivityStatus.working;
  final summary = [
    if (working > 0) '$working working',
    if (failed > 0) '$failed failed',
  ].join(', ');
  return _Status(
    icon: agentStatusAppearance(status).icon,
    glyph: StatusGlyph(status: status, size: Chrome.iconSmall),
    label: summary,
    compactLabel: '${working + failed}',
    tooltip: 'Agents: $summary. Their tabs show which.',
  );
}

_Status? _attention(WidgetRef ref, _Read read) {
  final count = read(attentionCountProvider);
  if (count == 0) return null;
  final room = read(sidePanelRoomProvider);
  return _Status(
    // The Inbox's own glyph, not a warning sign: the same count, the same list
    // and the same click as the rail.
    icon: AppIcons.tray,
    label: count == 1 ? '1 needs you' : '$count need you',
    compactLabel: '$count',
    tooltip:
        '${_plural(count, 'session')} waiting for you. '
        '${_panelAction(room, 'open the Inbox')}',
    tone: StatusBarTone.attention,
    onPressed: room ? () => _reveal(ref, SidePanelSurface.inbox) : null,
  );
}

_Status? _background(BuildContext context, WidgetRef ref, _Read read) {
  final count = read(
    terminalSessionsControllerProvider.select((s) => s.detached.length),
  );
  if (count == 0) return null;
  return _Status(
    icon: AppIcons.terminalWindow,
    label: '$count in background',
    compactLabel: '$count',
    tooltip:
        '${_plural(count, 'session')} running with no tab. '
        'Click to manage background sessions.',
    onPressed: () => TerminalActions(ref).showBackgroundSessions(context),
  );
}

_Status _tabs(_Read read) {
  // A count, not the terminal state: a process exiting anywhere used to
  // repaint this whole row.
  final count = read(
    terminalSessionsControllerProvider.select((s) => s.tabs.length),
  );
  return _Status(
    icon: AppIcons.terminal,
    label: _plural(count, 'tab'),
    compactLabel: '$count',
    tooltip: '${_plural(count, 'open tab')} in this window.',
  );
}

_Status _panel(WidgetRef ref, _Read read) {
  if (!read(sidePanelRoomProvider)) {
    return const _Status(
      icon: AppIcons.sidebarSimple,
      label: 'No room for panel',
      tooltip: kSidePanelNoRoom,
      enabled: false,
    );
  }
  final panel = read(sidePanelProvider);
  return _Status(
    icon: AppIcons.sidebarSimple,
    label: panel?.label ?? 'Panel closed',
    tooltip: panel == null
        ? 'Side panel closed. Click to open it.'
        : '${panel.label} is open. Click to close the side panel.',
    onPressed: () => ref.read(sidePanelProvider.notifier).toggle(),
  );
}

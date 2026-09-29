import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/server/remote_server_access.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../remote/presentation/use_auto_button.dart';
import '../../terminal/application/local_host_providers.dart';
import '../application/agent_states.dart';
import '../application/session_list_snapshot.dart';
import 'sidebar_chrome.dart';

/// "14:32", or "3 Oct, 14:32" when it was not today.
String lastSeenLabel(BuildContext context, DateTime savedAt) {
  final at = savedAt.toLocal();
  final now = DateTime.now();
  final time = TimeOfDay.fromDateTime(at).format(context);
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return time;
  }
  return '${MaterialLocalizations.of(context).formatShortMonthDay(at)}, $time';
}

/// **The last session list, stale** (decision 9): what this device saw of the
/// server when it was last connected, under a strip that says so. Nothing on
/// it can be acted on; a tap only shakes the strip.
class StaleSessionList extends ConsumerStatefulWidget {
  const StaleSessionList({required this.snapshot, super.key});

  final SessionListSnapshot snapshot;

  @override
  ConsumerState<StaleSessionList> createState() => _StaleSessionListState();
}

class _StaleSessionListState extends ConsumerState<StaleSessionList>
    with SingleTickerProviderStateMixin {
  late final _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  final _opened = <AgentState>{};

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  void _nudge() {
    if (Motion.of(context).animate) _shake.forward(from: 0);
  }

  void _toggle(AgentState state) => setState(() {
    if (!_opened.remove(state)) _opened.add(state);
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final items = <Widget>[];
    for (final group in snapshot.groups) {
      final opened = _opened.contains(group.state);
      final shown = switch (group.state.fold) {
        AgentStateFold.open => group.rows.length,
        AgentStateFold.capped =>
          opened
              ? group.rows.length
              : math.min(kReadyVisibleRows, group.rows.length),
        AgentStateFold.folded => opened ? group.rows.length : 0,
      };
      items.add(
        SidebarGroupLabel(
          key: ValueKey('stale-group:${group.state.name}'),
          label: group.state.label,
          count: '${group.total}',
          countTooltip: group.total == 1
              ? '1 session when last seen'
              : '${group.total} sessions when last seen',
          expanded: group.state.fold == AgentStateFold.folded ? opened : null,
          onTap: group.state.fold == AgentStateFold.folded
              ? () => _toggle(group.state)
              : null,
          spaceAbove: items.isNotEmpty,
        ),
      );
      for (final row in group.rows.take(shown)) {
        items.add(
          _StaleRow(
            key: ValueKey('stale:${row.id}'),
            row: row,
            state: group.state,
            onTap: _nudge,
          ),
        );
      }
      if (group.state.fold == AgentStateFold.capped &&
          group.rows.length > kReadyVisibleRows) {
        items.add(
          _MutedRow(
            key: ValueKey('stale-fold:${group.state.name}'),
            label: opened
                ? 'Show fewer'
                : 'Show ${group.rows.length - kReadyVisibleRows} more',
            onTap: () => _toggle(group.state),
          ),
        );
      }
      final unsaved = group.total - group.rows.length;
      if (unsaved > 0 && shown == group.rows.length) {
        items.add(
          _MutedRow(
            key: ValueKey('stale-unsaved:${group.state.name}'),
            label: '$unsaved more when connected',
            onTap: _nudge,
          ),
        );
      }
    }
    return Column(
      children: [
        AnimatedBuilder(
          animation: _shake,
          builder: (context, child) {
            final t = _shake.value;
            final dx = math.sin(t * math.pi * 6) * Insets.sm * (1 - t);
            return Transform.translate(offset: Offset(dx, 0), child: child);
          },
          child: _StaleStrip(savedAt: snapshot.savedAt),
        ),
        Expanded(
          child: ListView(padding: Sidebar.listPadding, children: items),
        ),
      ],
    );
  }
}

/// "Reconnecting… · last seen 14:32", or, once a dial has failed,
/// "Not connected · last seen 14:32 · Try again" over the dial's reason, and
/// *Use Auto* while the machine's route is pinned.
class _StaleStrip extends ConsumerWidget {
  const _StaleStrip({required this.savedAt});

  final DateTime savedAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(dataClientProvider);
    final connection =
        ref.watch(dataConnectionProvider).value ?? client.connection;
    // Dialling — the first dial, a redial after the app came back — or the
    // link held for a resume, is still reconnecting.
    final dialling = connection.state != DataLinkState.unavailable;
    final reason = connection.reason;
    final access = ref.watch(serverAccessProvider);
    if (access is! RemoteServerAccess) {
      return _strip(context, client, dialling, reason);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: access.resuming,
      builder: (context, held, _) =>
          _strip(context, client, dialling || held, reason),
    );
  }

  Widget _strip(
    BuildContext context,
    DataClient client,
    bool dialling,
    String? reason,
  ) {
    final theme = Theme.of(context);
    final attention = SemanticColors.of(context).attention;
    final seen = 'last seen ${lastSeenLabel(context, savedAt)}';
    final words = dialling ? 'Reconnecting… · $seen' : 'Not connected · $seen';
    // Why, once the dials have given up: a pinned route is named here.
    final why = dialling ? null : reason;
    return Semantics(
      liveRegion: true,
      container: true,
      hint: 'This list is not live; nothing on it can be opened.',
      child: Material(
        key: const ValueKey('stale-session-strip'),
        color: SurfaceTones.of(context).attentionSurface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Touch.target),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.md),
            child: Row(
              children: [
                Icon(
                  dialling ? AppIcons.arrowClockwise : AppIcons.warningCircle,
                  size: Chrome.icon,
                  color: attention,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: why == null ? 0 : Insets.xs,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          words,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (why != null)
                          Text(
                            why,
                            key: const ValueKey('stale-session-strip-reason'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const UseAutoButton(),
                if (!dialling)
                  TextButton(
                    onPressed: client.retry,
                    child: const Text('Try again'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of the stale list: dimmed, with no menu and no live glyph.
class _StaleRow extends ConsumerWidget {
  const _StaleRow({
    required this.row,
    required this.state,
    required this.onTap,
    super.key,
  });

  final SnapshotRow row;
  final AgentState state;
  final VoidCallback onTap;

  static IconData _glyph(AgentState state, String? waitWord) => switch (state) {
    AgentState.needsYou =>
      waitWord == 'question' ? AppIcons.question : AppIcons.shield,
    AgentState.quiet => AppIcons.pauseCircle,
    AgentState.working => AppIcons.circleHalf,
    AgentState.failed => AppIcons.xCircle,
    AgentState.ready => AppIcons.circle,
    AgentState.ended => AppIcons.checkCircle,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final muted = density.muted(theme);
    final dim = theme.colorScheme.onSurfaceVariant;
    final activityAt = row.activityAt;
    final tail =
        row.waitWord ??
        (activityAt == null
            ? null
            : compactAge(
                ref.read(clockProvider).nowUtc().difference(activityAt),
              ));
    final project = row.projectName;
    final agentId = row.agentId;
    return Semantics(
      label:
          '${row.title}, ${state.label}${tail == null ? '' : ', $tail'}, '
          'when last seen',
      excludeSemantics: true,
      child: Opacity(
        opacity: 0.6,
        child: ExplorerRow(
          kind: ExplorerRowKind.session,
          minHeight: Sidebar.rowHeight,
          depth: 0,
          selected: false,
          settled: true,
          onTap: onTap,
          builder: (context) => Row(
            children: [
              SizedBox(
                width: ExplorerRow.glyphSlot,
                child: Center(
                  child: Icon(
                    _glyph(state, row.waitWord),
                    size: ExplorerRow.glyphSize,
                    color: dim,
                  ),
                ),
              ),
              const SizedBox(width: ExplorerRow.textGap),
              Expanded(
                child: Row(
                  children: [
                    if (agentId != null) ...[
                      SizedBox.square(
                        dimension: ExplorerRow.glyphSize,
                        child: Center(
                          child: AgentLogo(
                            agentId: agentId,
                            size: ExplorerRow.glyphSize,
                          ),
                        ),
                      ),
                      SizedBox(width: density.glyphGap),
                    ],
                    Flexible(
                      flex: 3,
                      child: Text(
                        row.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: density.rowTitle(theme),
                      ),
                    ),
                    if (project != null && project.isNotEmpty) ...[
                      const SizedBox(width: Insets.sm),
                      Flexible(
                        flex: 2,
                        child: Text(
                          project,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (tail != null) ...[
                const SizedBox(width: Insets.xs),
                Text(tail, style: muted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MutedRow extends StatelessWidget {
  const _MutedRow({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ExplorerRow(
    kind: ExplorerRowKind.session,
    minHeight: Sidebar.rowHeight,
    depth: 0,
    selected: false,
    onTap: onTap,
    builder: (context) => ExplorerRowLine(
      lead: const ExplorerRowLead(),
      title: Text(label, style: UiDensity.of(context).muted(Theme.of(context))),
    ),
  );
}

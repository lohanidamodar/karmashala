import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_permission_options.dart';
import '../../settings/domain/permission_mode.dart';
import '../application/session_launcher.dart';
import '../application/session_signals.dart';

/// The composer's permission control: the mode this session will run under, and
/// a menu of the modes its agent can actually be put into.
///
/// Three rules, each of which is the fix for something:
///
/// * **It shows the *effective* mode**, resolved by `SessionLauncher` — the same
///   call the launcher makes. The chip cannot drift from the command line
///   because there is no second resolution to drift from.
/// * **Only modes the descriptor can express are selectable** (Loop 31 §4,
///   option C). The rest are listed, disabled, and say why. The user cannot ask
///   for something that would be silently dropped.
/// * **A session following the default says so, and can go back to it.** The
///   resolved mode drawn bare would read as this session's own decision, when
///   in fact it tracks the Settings default and moves when that moves — two
///   states that must not look alike. The menu's first row is the way back,
///   without which the first pick would be irreversible.
/// * **Changing it does not touch the running process.** Every agent here reads
///   its permission policy off the command line at startup, so the chip says the
///   change applies on the next launch instead of implying the live agent has
///   been re-governed.
/// One row of the permission menu: a mode to set for this session, or the
/// Settings default to hand it back to.
///
/// A type of its own rather than a nullable [PermissionMode] because
/// `PopupMenuButton` reads a null selection as a *dismissal* and never calls
/// `onSelected` for it — so "follow the default" written as a null value would
/// have looked right and done nothing.
@immutable
class PermissionChoice {
  const PermissionChoice(this.mode);

  /// Follow the per-agent default in Settings, live.
  static const followDefault = PermissionChoice(null);

  final PermissionMode? mode;

  @override
  bool operator ==(Object other) =>
      other is PermissionChoice && other.mode == mode;

  @override
  int get hashCode => mode.hashCode;
}

class PermissionModeChip extends ConsumerWidget {
  const PermissionModeChip({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The row is what the mode lives on, so a write has to be able to redraw
    // this — and only a write to *this* row does. `setPermissionMode`
    // publishes `SessionChange.reconfigured` against the same id.
    ref.watchSession(sessionId);
    final launcher = ref.read(sessionLauncherProvider);
    final effective = launcher.effectivePermissionFor(sessionId);
    if (effective == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final options = permissionOptionsFor(effective.descriptor);
    final current = options.firstWhere((o) => o.mode == effective.mode);

    // Colour carries meaning only: a mode we cannot enforce and a bypass are
    // both things the user should notice, and nothing else is tinted.
    final alarming =
        current.fit == PermissionModeFit.none || current.mode.isDangerous;
    final foreground = alarming ? scheme.error : scheme.onSurfaceVariant;

    return PopupMenuButton<PermissionChoice>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: (choice) =>
          _apply(context, ref, launcher, choice.mode, current),
      itemBuilder: (context) => [
        // First, and its own row: handing the session back to the Settings
        // default is where every session starts and the only state that follows
        // a later change to that setting.
        PopupMenuItem<PermissionChoice>(
          value: PermissionChoice.followDefault,
          child: _DefaultRow(resolved: current, selected: effective.inherited),
        ),
        const PopupMenuDivider(),
        for (final option in options)
          PopupMenuItem<PermissionChoice>(
            value: PermissionChoice(option.mode),
            enabled: option.isSelectable,
            child: _MenuRow(
              option: option,
              selected: !effective.inherited && option.mode == current.mode,
            ),
          ),
      ],
      child: Tooltip(
        message: _tooltip(current, inherited: effective.inherited),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: 3,
          ),
          // The composer bar has exactly one flexible cell — the delivery strip
          // — and this is not it, so an unbounded chip pushes the whole row
          // into overflow at the minimum window with Windows' largest text
          // step. A third of the window is the most this control may take;
          // past that it gives up the tail of a qualifier rather than the row.
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width / 3,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _iconFor(current.fit, current.mode),
                size: 13,
                color: foreground,
              ),
              const SizedBox(width: Insets.xs),
              // The mode's own name is the last thing to be given up, so it is
              // rigid and the qualifiers below are not.
              Text(
                current.mode.shortLabel,
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
              ),
              // Both qualifiers are on the chip, not only in the tooltip.
              // "Accept edits" that is really Codex's sandbox has to look
              // different from one that really is accept-edits, and a mode this
              // session is merely *following* has to look different from one it
              // chose — neither is discoverable by hovering.
              for (final qualifier in [
                if (effective.inherited) 'default',
                if (current.fit != PermissionModeFit.exact) current.fitLabel,
              ]) ...[
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Text(
                    '· $qualifier',
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ],
              Icon(AppIcons.caretDown, size: 11, color: foreground),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(PermissionModeFit fit, PermissionMode mode) =>
      switch (fit) {
        PermissionModeFit.none => AppIcons.warningCircle,
        PermissionModeFit.approximate => AppIcons.info,
        PermissionModeFit.exact =>
          mode.isDangerous ? AppIcons.warning : AppIcons.check,
      };

  String _tooltip(AgentPermissionOption current, {required bool inherited}) {
    // "Following" rather than "inherited": inheriting sounds like something
    // that happened once, and the whole point of this state is that it is live
    // — change the setting and this session changes with it.
    final origin = inherited
        ? 'Following the ${current.agentName} default in Settings, so it '
              'changes when that setting does.'
        : 'Set for this session, and it stays set when the Settings default '
              'changes.';
    return '${current.mode.label}\n$origin\n${current.summary}';
  }

  void _apply(
    BuildContext context,
    WidgetRef ref,
    SessionLauncher launcher,
    PermissionMode? mode,
    AgentPermissionOption current,
  ) {
    final messenger = ScaffoldMessenger.of(context);
    final running = launcher.livePaneFor(sessionId) != null;
    launcher.setPermissionMode(sessionId, mode);
    // Only claim what happened. A live agent was started with the old flags and
    // there is no documented way to re-govern any of these CLIs mid-session, so
    // saying anything else here would be the lie this control exists to remove.
    final what = mode == null
        ? 'Following the ${current.agentName} default in Settings'
        : mode.label;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          running
              ? '$what — applies the next time this session is '
                    'launched or resumed, not to the agent running now.'
              : '$what — applies when this session next runs.',
        ),
      ),
    );
  }
}

/// The menu's first row: hand this session back to the Settings default.
///
/// It names what the default resolves to *today* rather than only offering the
/// idea, because "follow the default" is not an answer to "what will this run
/// under" — and that is the question the user opened this menu with.
class _DefaultRow extends StatelessWidget {
  const _DefaultRow({required this.resolved, required this.selected});

  final AgentPermissionOption resolved;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          child: selected
              ? Icon(AppIcons.check, size: 13, color: scheme.primary)
              : null,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Follow the Settings default',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                'Currently ${resolved.mode.label.toLowerCase()} for '
                '${resolved.agentName}. Changing that setting changes this '
                'session too.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.option, required this.selected});

  final AgentPermissionOption option;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = !option.isSelectable;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          child: selected
              ? Icon(AppIcons.check, size: 13, color: scheme.primary)
              : null,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      option.mode.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted ? scheme.onSurfaceVariant : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(
                    option.fitLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: switch (option.fit) {
                        PermissionModeFit.exact => scheme.onSurfaceVariant,
                        PermissionModeFit.approximate => scheme.tertiary,
                        PermissionModeFit.none => scheme.error,
                      },
                    ),
                  ),
                ],
              ),
              Text(
                option.summary,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

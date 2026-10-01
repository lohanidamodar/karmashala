import '../../environments/application/environment_values.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_terminal_core/shell_integration.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart' show StatusDot;
import 'package:karmashala_ui/rows.dart' show abbreviatePath;
import 'package:karmashala_ui/tokens.dart';

import '../application/shell_status.dart';
import '../application/terminal_sessions_controller.dart';

/// The gap between two facts on the line (board A2: `gap: 14`).
const double _factGap = Insets.md;

/// The pane group [groupId]'s shell status line describes: the focused pane of
/// its active tab, when that pane is a **plain shell** of ours. Null for a
/// document tab, an empty region, and an agent's pane — an agent pane with no
/// session row yet is not a shell, and calling it one would be a false fact.
String? shellStatusPaneOf(WidgetRef ref, String groupId) {
  final tabId = ref.watch(workspaceGroupActiveTabProvider(groupId));
  if (tabId == null) return null;
  final paneId = ref.watch(
    terminalSessionsControllerProvider.select((s) {
      for (final tab in s.tabs) {
        if (tab.id == tabId) return tab.focusedPaneId;
      }
      return null;
    }),
  );
  if (paneId == null) return null;
  final instance = ref
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId);
  if (instance == null || instance.agentLaunch != null) return null;
  return paneId;
}

/// **A plain terminal's status line** (spec §4, board A2 `active.isShell`): the
/// shell and whether it is running, the folder it is in, the branch there, then
/// the last command's exit code and the machine at the far end.
///
/// Only the *contents*: the bar around it — height, tone, Zen dimming — is the
/// session status line's own, so a shell tab and an agent tab share one foot.
/// A fact nothing established is left out; the line never guesses one.
///
/// [shellStatusPaneOf] says whether a group's tab has a pane this line is for.
class ShellStatusLine extends ConsumerStatefulWidget {
  const ShellStatusLine({required this.paneId, super.key});

  /// The pane this line describes — the focused pane of its group's tab.
  final String paneId;

  @override
  ConsumerState<ShellStatusLine> createState() => _ShellStatusLineState();
}

class _ShellStatusLineState extends ConsumerState<ShellStatusLine> {
  /// The tracker [_onCompleted] is registered with. Held so a reattach, which
  /// swaps the pane's instance, moves the listener to the new one.
  CommandBlockTracker? _tracker;

  /// The last finished command's exit code. Null before one has finished, or
  /// when the shell ended it without saying (an interrupt with no `D`).
  int? _lastExit;

  /// The directory the branch was last read for, so a finished command can
  /// have it read again — a `git switch` typed in the pane lands then.
  EnvironmentPath? _branchDirectory;

  @override
  void dispose() {
    _tracker?.removeCompletionListener(_onCompleted);
    super.dispose();
  }

  /// Follows [tracker]. The tracker exposes completions as callbacks, not a
  /// listenable, so the line subscribes itself and rebuilds on each one.
  void _bind(CommandBlockTracker? tracker) {
    if (identical(tracker, _tracker)) return;
    _tracker?.removeCompletionListener(_onCompleted);
    _tracker = tracker;
    tracker?.addCompletionListener(_onCompleted);
    // What the tracker already holds, so a line mounted on a pane with history
    // starts from its last command rather than from nothing.
    final blocks = tracker?.blocks ?? const <CommandBlock>[];
    _lastExit = blocks.isEmpty ? null : blocks.last.exitCode;
  }

  void _onCompleted(CommandBlock block) {
    if (!mounted) return;
    setState(() => _lastExit = block.exitCode);
    if (_branchDirectory case final directory?) {
      ref.invalidate(shellBranchProvider(directory));
    }
  }

  @override
  Widget build(BuildContext context) {
    final paneId = widget.paneId;
    // The tab list moves when a pane is reattached to a new instance; liveness
    // and directory are this pane's own slices, so a sibling pane's `cd` or
    // exit does not rebuild this line.
    ref.watch(terminalSessionsControllerProvider.select((s) => s.tabs));
    final liveness = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.livenessOf(paneId)),
    );
    final path = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.directoryOf(paneId)),
    );
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    _bind(instance?.commandBlocks?.tracker);
    if (instance == null) return const SizedBox.shrink();

    final profile = ref.watch(shellProfileProvider(instance.profileId));
    final environmentId = ref.watch(
      shellEnvironmentIdProvider(instance.profileId),
    );
    final machine = environmentId == null
        ? null
        : ref.watch(shellEnvironmentLabelProvider(environmentId));
    final directory = path == null || path.isEmpty || environmentId == null
        ? null
        : EnvironmentPath(environmentId: environmentId, path: path);
    _branchDirectory = directory;
    // `.value`: a re-read keeps the branch it had rather than blinking out.
    final branch = directory == null
        ? null
        : ref.watch(shellBranchProvider(directory)).value;

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final label = theme.textTheme.labelSmall;
    final muted = label?.copyWith(color: scheme.onSurfaceVariant);
    final mono = MonoStyles.small.copyWith(color: scheme.onSurfaceVariant);
    final live = liveness.isLive;
    // The shell's own status once it has gone; the last command's while it runs.
    final exitCode = live ? _lastExit : instance.exitCode;
    final failed = exitCode != null && exitCode != 0;

    final left = <Widget>[
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(
            color: live ? semantic.idle : semantic.neutral,
            label: live ? 'Running' : 'Exited',
          ),
          if (profile != null) ...[
            const SizedBox(width: Insets.xs),
            Text(
              profile.label,
              style: label?.copyWith(color: scheme.onSurface),
            ),
          ],
        ],
      ),
      if (path != null && path.isNotEmpty)
        Tooltip(
          message: path,
          child: Text(abbreviatePath(path).first, style: mono),
        ),
      if (branch != null && branch.isNotEmpty)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.gitBranch,
              size: Chrome.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.xs),
            Text(branch, style: mono),
          ],
        ),
    ];
    final right = <Widget>[
      if (!live)
        Text(
          exitCode == null ? 'exited' : 'exited $exitCode',
          style: failed ? label?.copyWith(color: semantic.failure) : muted,
        )
      else if (exitCode != null)
        Text(
          'last exit $exitCode',
          style: failed ? label?.copyWith(color: semantic.failure) : muted,
        ),
      if (machine != null) Text(machine, style: muted),
    ];

    // Spread across the bar at width, scrolled as one run when narrower than
    // its facts — squeezed, none of them would stay legible. The bar is a
    // column child, never measured by intrinsics, so reading its width is safe.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          // Unbounded along the scroll, the row sizes to its facts, then grows
          // to the minimum; `spaceBetween` puts the width it gained between
          // the two halves, which is the board's spacer.
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _Facts(children: left),
              if (right.isNotEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: _factGap),
                  child: _Facts(children: right),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One run of facts, [_factGap] apart.
class _Facts extends StatelessWidget {
  const _Facts({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (index, child) in children.indexed) ...[
        if (index > 0) const SizedBox(width: _factGap),
        child,
      ],
    ],
  );
}

part of 'workbench.dart';

/// Marks the workbench as the phone's session page (Stage 2 step 3). Set by
/// the phone shell, which `AppShell` picks by width, so a narrow desktop
/// window draws the same page and a wide one never sees it.
class CompactWorkbenchScope extends InheritedWidget {
  const CompactWorkbenchScope({required super.child, super.key});

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CompactWorkbenchScope>() != null;

  @override
  bool updateShouldNotify(CompactWorkbenchScope oldWidget) => false;
}

/// The most a waiting resume takes of the phone's bar row: its countdown and
/// cancel, leaving the delivery line its words.
const double _compactResumeChipWidth = 180;

/// **Chat / Terminal** in the phone's app bar: the bar's [_ViewToggle], moved
/// up for the focused group, which is the only one a phone shows.
class WorkbenchFaceToggle extends ConsumerWidget {
  const WorkbenchFaceToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupId = ref.watch(focusedWorkspaceGroupProvider);
    if (groupId == null) return const SizedBox.shrink();
    if (ref.watch(workspaceGroupActiveTabProvider(groupId)) == null) {
      return const SizedBox.shrink();
    }
    final session = _groupSessionOf(ref, groupId);
    // One face, nothing to toggle to.
    if (session == null || session.chatOnly) return const SizedBox.shrink();
    final onTerminal = ref.watch(terminalVisibleInGroupProvider(groupId));
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    return _ViewToggle(
      onTerminal: onTerminal,
      compact: true,
      touch: true,
      onChat: () => terminals
        ..focusGroup(groupId)
        ..showFaceIn(groupId, terminal: false),
      onTerminalView: () {
        terminals.focusGroup(groupId);
        showTerminalFor(ref, session.paneId, session.id);
      },
    );
  }
}

/// The status bar folded to one row: the delivery facts, the permission mode
/// and **Session ▾**, whose sheet is the row's overflow. The same row in the
/// chat and the terminal; the toggle is in the app bar.
class _CompactSessionBar extends StatelessWidget {
  const _CompactSessionBar({
    required this.sessionId,
    required this.reading,
    required this.onTerminal,
  });

  final String? sessionId;
  final bool reading;

  /// The terminal is showing: its prompt is answered on the terminal, with
  /// the key row, so the dock stays in the chat (owner, 2026-09-30).
  final bool onTerminal;

  @override
  Widget build(BuildContext context) {
    final sessionId = this.sessionId;
    if (sessionId == null) return const SizedBox.shrink();
    final tones = SurfaceTones.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!onTerminal)
          ColoredBox(
            color: tones.term,
            child: ApprovalRequestCard(
              sessionId: sessionId,
              docked: true,
              touch: true,
            ),
          ),
        Container(
          constraints: const BoxConstraints(minHeight: Touch.target),
          color: tones.chrome,
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          child: _HeldHeight(
            hold: reading,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: Touch.target),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DeliveryStateLine(sessionId: sessionId),
                        ),
                      ),
                      // The mode chip is in the sheet: at phone width it
                      // squeezed the delivery line to a word. A waiting
                      // resume is not: its countdown and cancel stay in view.
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: _compactResumeChipWidth,
                        ),
                        child: ScheduledResumeChip(sessionId: sessionId),
                      ),
                      const SizedBox(width: Insets.xs),
                      _SessionSheetButton(sessionId: sessionId),
                    ],
                  ),
                ),
                SessionNoticeLine(sessionId: sessionId),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// **Session ▾**: opens [_SessionSheet].
class _SessionSheetButton extends StatelessWidget {
  const _SessionSheetButton({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TextButton(
      key: const ValueKey('session-sheet'),
      style: TextButton.styleFrom(
        minimumSize: const Size(Touch.target, Touch.target),
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
        foregroundColor: scheme.onSurface,
      ),
      onPressed: () => showAdaptiveModal<void>(
        context: context,
        title: 'Session',
        builder: (_) => _SessionSheet(sessionId: sessionId),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Session', style: theme.textTheme.labelMedium),
          const SizedBox(width: Insets.xs),
          Icon(
            AppIcons.caretDown,
            size: Chrome.iconSmall,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// What the wide status line holds beyond the phone's row: the model, the
/// stats, every delivery step, and ⋯'s verbs.
class _SessionSheet extends StatelessWidget {
  const _SessionSheet({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.labelSmall
        ?.merge(Chrome.groupLabel)
        .copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget row(Widget child) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Touch.target),
      child: Align(alignment: AlignmentDirectional.centerStart, child: child),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('MODEL AND MODE', style: label),
          row(
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SessionModelChip(sessionId: sessionId),
                PermissionModeChip(sessionId: sessionId),
                SessionModePicker(sessionId: sessionId, leadingGap: false),
                OperatorChip(sessionId: sessionId),
                SessionStatsButton(sessionId: sessionId),
              ],
            ),
          ),
          const SizedBox(height: Insets.sm),
          row(DeliveryStrip(sessionId: sessionId, hostedOnTerminal: true)),
          const SizedBox(height: Insets.sm),
          SessionMoreBody(sessionId: sessionId),
        ],
      ),
    );
  }
}

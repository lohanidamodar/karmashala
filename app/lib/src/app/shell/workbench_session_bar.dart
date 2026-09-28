part of 'workbench.dart';

/// The width, at 1x text, the bar is one status line from: facts, stats,
/// mode, model, the next step, Ship ▾ and the toggle. Below it the facts
/// become a caption over the controls.
const double _sessionBarThirdControlWidth = 820;

/// Below this, at 1x text, the action row draws its verbs as glyphs: a
/// two-way split leaves a group 363px.
const double _sessionBarNarrowWidth = 560;

/// Below this the facts line scrolls rather than being squeezed illegible.
const double _sessionFactsScrollWidth = 240;

/// The most a model name may take before it ends.
const double _sessionModelLabelWidth = 72;

/// The chrome under the surface: what belongs to the session on screen. It
/// speaks for the *focused pane's* session, never the Explorer's selection.
class _SessionBar extends ConsumerWidget {
  const _SessionBar({
    required this.groupId,
    required this.session,
    required this.onTerminal,
    required this.onChat,
    required this.onTerminalView,
  });

  /// The group this bar belongs to. **Its** session is what it describes — see
  /// [_WorkspaceGroup] for why that must not be the focused one.
  final String? groupId;

  final _WorkbenchSession? session;
  final bool onTerminal;
  final VoidCallback onChat;
  final VoidCallback onTerminalView;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = session;
    final group = groupId;
    // The same bar in both views (owner, 2026-09-28): in the chat it describes
    // the session the chat shows.
    final sessionId = !onTerminal
        ? selected?.id
        : selected != null && selected.paneId == null
        ? selected.id
        : group == null
        ? null
        : ref.watch(workspaceGroupSessionIdProvider(group));
    // A shell tab with nothing selected has neither a session to describe nor a
    // surface to switch to, and an empty bar would be 30 pixels of nothing.
    if (sessionId == null && selected == null) return const SizedBox.shrink();

    // Whether the bar has been told what it is describing yet: only "never had
    // an answer for *this* session" counts, so a refresh moves nothing.
    final reading =
        sessionId != null &&
        ref.watch(
          sessionDeliveryProvider(
            sessionId,
          ).select((d) => d.isLoading && !d.hasValue),
        );

    final textScaler = MediaQuery.textScalerOf(context);
    final thirdControl = WidthClass.scaleBreakpoint(
      _sessionBarThirdControlWidth,
      textScaler,
    );
    final narrowBelow = WidthClass.scaleBreakpoint(
      _sessionBarNarrowWidth,
      textScaler,
    );
    final toggle = selected == null
        ? null
        : (bool compact) => _ViewToggle(
            onTerminal: onTerminal,
            onChat: onChat,
            onTerminalView: onTerminalView,
            compact: compact,
          );
    // A tone step, not a rule, parts the bar from the surface above it.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: Chrome.tabStrip),
          color: SurfaceTones.of(context).chrome,
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: 2,
          ),
          // Inside the [Container], so the bar's own surface grows with the
          // reservation instead of leaving the terminal showing through.
          child: _HeldHeight(
            hold: reading,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // **The ask dock** (spec §5): what the agent is waiting on,
                // answerable here, above the line that describes it. Nothing
                // at all while it is not waiting.
                if (sessionId != null)
                  ApprovalRequestCard(sessionId: sessionId, docked: true),
                // At width the pane's status is one line: the facts, then the
                // controls. Below it the facts are a caption over the controls.
                if (sessionId != null)
                  LayoutBuilder(
                    builder: (context, constraints) =>
                        constraints.maxWidth < thirdControl
                        ? const SizedBox.shrink()
                        : _SessionStatusLine(
                            sessionId: sessionId,
                            toggle: toggle?.call(false),
                          ),
                  ),
                if (sessionId != null) SessionNoticeLine(sessionId: sessionId),
                if (sessionId != null) ...[
                  // The bar's own width: a `LayoutBuilder` inside the row would
                  // read infinity for a non-flexible child.
                  LayoutBuilder(
                    builder: (context, constraints) =>
                        constraints.maxWidth >= thirdControl
                        ? const SizedBox.shrink()
                        : _SessionFactsRow(sessionId: sessionId),
                  ),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    if (sessionId != null &&
                        constraints.maxWidth >= thirdControl) {
                      return const SizedBox.shrink();
                    }
                    final narrow = constraints.maxWidth < narrowBelow;
                    return _SessionActionRow(
                      sessionId: sessionId,
                      narrow: narrow,
                      toggle: toggle?.call(narrow),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// **The pane's status line** (spec §5), at width: the delivery facts and the
/// session's stats on the left; mode, model, the next delivery step and
/// **Ship ▾** on the right, then the view toggle.
class _SessionStatusLine extends StatelessWidget {
  const _SessionStatusLine({required this.sessionId, required this.toggle});

  final String sessionId;
  final Widget? toggle;

  @override
  Widget build(BuildContext context) {
    final toggle = this.toggle;
    return Row(
      children: [
        // One line, whatever the branch is called: the facts slide under the
        // controls rather than wrapping the bar to a second row. The resume
        // chip rides with them: it is nothing, and no width, until armed.
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                DeliveryStateLine(sessionId: sessionId),
                ScheduledResumeChip(sessionId: sessionId),
              ],
            ),
          ),
        ),
        SessionStatsButton(sessionId: sessionId),
        const SizedBox(width: Insets.sm),
        PermissionModeChip(sessionId: sessionId),
        const SizedBox(width: Insets.xs),
        SessionModelChip(
          sessionId: sessionId,
          maxLabelWidth: _sessionModelLabelWidth,
        ),
        const SizedBox(width: Insets.sm),
        DeliveryStrip(
          sessionId: sessionId,
          hostedOnTerminal: true,
          folded: true,
        ),
        if (toggle != null) ...[const SizedBox(width: Insets.sm), toggle],
      ],
    );
  }
}

/// The caption over the action row, below the status line's width: the
/// delivery state. Usage is per account, so it is in the toolbar.
class _SessionFactsRow extends StatelessWidget {
  const _SessionFactsRow({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        // Scrolled rather than squeezed: under the floor, sharing the pixels
        // out leaves none of them legible.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final line = DeliveryStateLine(sessionId: sessionId);
            return constraints.maxWidth < _sessionFactsScrollWidth
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: line,
                  )
                : line;
          },
        ),
      ),
      // Nothing, and no width, until one is armed.
      Flexible(child: ScheduledResumeChip(sessionId: sessionId)),
    ],
  );
}

/// The session's controls — permission mode, model, delivery — and the view
/// toggle. [narrow] scrolls the controls in one run instead of wrapping them.
class _SessionActionRow extends StatelessWidget {
  const _SessionActionRow({
    required this.sessionId,
    required this.toggle,
    required this.narrow,
  });

  final String? sessionId;
  final Widget? toggle;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final sessionId = this.sessionId;
    final toggle = this.toggle;
    if (narrow) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: sessionId == null
                ? const SizedBox.shrink()
                // Scrolled rather than squeezed, at a split's smallest group.
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PermissionModeChip(sessionId: sessionId),
                        const SizedBox(width: Insets.xs),
                        DeliveryStrip(
                          sessionId: sessionId,
                          hostedOnTerminal: true,
                          compact: true,
                          folded: true,
                        ),
                      ],
                    ),
                  ),
          ),
          if (toggle != null) ...[const SizedBox(width: Insets.sm), toggle],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sessionId == null)
          const Spacer()
        else ...[
          PermissionModeChip(sessionId: sessionId),
          const SizedBox(width: Insets.xs),
          // Flexible, and the only control that is: a model name is the one
          // label whose width is unpredictable.
          Flexible(
            child: SessionModelChip(
              sessionId: sessionId,
              maxLabelWidth: _sessionModelLabelWidth,
            ),
          ),
          const SizedBox(width: Insets.sm),
          // The next step, and the rest behind Ship ▾: one run, one height,
          // and it gives way (its labels end) before the row overflows.
          Expanded(
            flex: 2,
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
        if (toggle != null) ...[const SizedBox(width: Insets.sm), toggle],
      ],
    );
  }
}

/// A box that keeps the height it last laid out at, while [hold] is set. The
/// height belongs to the width it was measured at; a resize gets none.
class _HeldHeight extends SingleChildRenderObjectWidget {
  const _HeldHeight({required this.hold, required super.child});

  final bool hold;

  @override
  _RenderHeldHeight createRenderObject(BuildContext context) =>
      _RenderHeldHeight(hold);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderHeldHeight renderObject,
  ) => renderObject.hold = hold;
}

class _RenderHeldHeight extends RenderProxyBox {
  _RenderHeldHeight(this._hold);

  bool _hold;
  set hold(bool value) {
    if (_hold == value) return;
    _hold = value;
    markNeedsLayout();
  }

  /// The height the child last asked for while nothing was being held, and the
  /// width it asked for it at.
  double? _settledHeight;
  double? _settledWidth;

  /// The floor [_settledHeight] imposes under [constraints], if any.
  double _floor(BoxConstraints constraints) =>
      _hold && _settledWidth == constraints.maxWidth ? _settledHeight ?? 0 : 0;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    if (_settledWidth != constraints.maxWidth) {
      _settledWidth = constraints.maxWidth;
      _settledHeight = null;
    }
    if (!_hold) _settledHeight = child.size.height;
    size = constraints.constrain(
      Size(child.size.width, math.max(child.size.height, _floor(constraints))),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final natural = super.computeDryLayout(constraints);
    return constraints.constrain(
      Size(natural.width, math.max(natural.height, _floor(constraints))),
    );
  }
}

/// The two renderings of one session — not navigation: both sides show the same
/// record, the same PTY and the same lifecycle. The only way to the transcript.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({
    required this.onTerminal,
    required this.onChat,
    required this.onTerminalView,
    this.compact = false,
  });

  final bool onTerminal;
  final VoidCallback onChat;
  final VoidCallback onTerminalView;

  /// Glyphs only, for a group too narrow to spell the two words; the tooltip
  /// and the semantics label are unchanged.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // The mockup's switch: a raised well with the chosen half lifted in the
    // selection tone — no outline.
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: SurfaceTones.of(context).raised,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ViewToggleHalf(
            icon: AppIcons.terminal,
            label: 'Terminal',
            tooltip: 'Terminal view',
            selected: onTerminal,
            compact: compact,
            onTap: onTerminalView,
          ),
          _ViewToggleHalf(
            icon: AppIcons.chatCircle,
            label: 'Chat',
            tooltip: 'Chat view',
            selected: !onTerminal,
            compact: compact,
            onTap: onChat,
          ),
        ],
      ),
    );
  }
}

/// One side of [_ViewToggle].
class _ViewToggleHalf extends StatelessWidget {
  const _ViewToggleHalf({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final IconData icon;
  final String label;

  /// Also the semantics label, which a [compact] half still needs.
  final String tooltip;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: InkWell(
          onTap: onTap,
          child: Container(
            // Padded rather than fixed at 22px: the halves must grow with the
            // ambient text scale or the row loses its shared centre-line.
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: kBarControlPad,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? SurfaceTones.of(context).selected
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.sm - 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: Chrome.iconSmall, color: colour),
                if (!compact) ...[
                  const SizedBox(width: Insets.xs),
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(color: colour),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

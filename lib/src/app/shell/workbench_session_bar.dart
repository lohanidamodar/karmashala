part of 'workbench.dart';

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
    final sessionId = !onTerminal
        ? null
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

    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Container(
          constraints: const BoxConstraints(minHeight: Chrome.tabStrip),
          color: scheme.surfaceContainerLow,
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
                // Full width and above everything, so the facts read as a caption
                // over the row rather than as the first item in it.
                if (sessionId != null) ...[
                  LayoutBuilder(
                    builder: (context, constraints) {
                      // The bar's own width. A `LayoutBuilder` *inside* the row
                      // would read infinity: a non-flexible child of a `Row` is
                      // measured unbounded along the main axis.
                      final scale =
                          MediaQuery.textScalerOf(context).scale(14) / 14;
                      // The same width the action row buys its third control
                      // at — a group too narrow for the model chip is too
                      // narrow for this, and the usage chip beside it overflows
                      // by 11px before it yields.
                      final roomForStats = constraints.maxWidth >= 820 * scale;
                      return Row(
                    children: [
                      Expanded(
                        // Scrolled rather than squeezed: under 240px, sharing
                        // the pixels out leaves none of them legible.
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final line = DeliveryStateLine(
                              sessionId: sessionId,
                            );
                            return constraints.maxWidth < 240
                                ? SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: line,
                                  )
                                : line;
                          },
                        ),
                      ),
                      // In the facts line and not the action row: a quota is not
                      // a control and must not compete for those pixels. What
                      // this session cost is the same kind of thing, and the
                      // action row has none to give — a fixed child there takes
                      // them from the model chip, which then overflows.
                      if (roomForStats) ...[
                        SessionStatsButton(sessionId: sessionId),
                        const SizedBox(width: Insets.xs),
                      ],
                      Flexible(child: UsageChip(sessionId: sessionId)),
                    ],
                      );
                    },
                  ),
                  // Whatever this session has just been told, over the chips
                  // that post it.
                  SessionNoticeLine(sessionId: sessionId),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    // Whether a third control fits, measured: at 720px the row
                    // is already 14px over, and 23px at the 1.3x text step.
                    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                    final roomForModel = constraints.maxWidth > 820 * scale;
                    // A group is a fraction of the window — a two-way split
                    // leaves 363px. Below this the row scrolls instead.
                    final narrow = constraints.maxWidth < 560 * scale;
                    final toggle = selected == null
                        ? null
                        : _ViewToggle(
                            onTerminal: onTerminal,
                            onChat: onChat,
                            onTerminalView: onTerminalView,
                            compact: narrow,
                          );
                    if (narrow) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: sessionId == null
                                ? const SizedBox.shrink()
                                : SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        PermissionModeChip(
                                          sessionId: sessionId,
                                        ),
                                        const SizedBox(width: Insets.xs),
                                        // Unbounded, so the `Wrap` lays out in
                                        // one run and the bar keeps one height.
                                        DeliveryStrip(
                                          sessionId: sessionId,
                                          hostedOnTerminal: true,
                                          compact: true,
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                          if (toggle != null) ...[
                            const SizedBox(width: Insets.sm),
                            toggle,
                          ],
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
                          // Flexible, and the only control that is: a model
                          // name is the one label whose width is unpredictable.
                          if (roomForModel) ...[
                            Flexible(
                              child: SessionModelChip(
                                sessionId: sessionId,
                                maxLabelWidth: 72,
                              ),
                            ),
                            const SizedBox(width: Insets.sm),
                          ],
                          // The delivery actions take the room the other two do
                          // not, and wrap *within* this box.
                          Expanded(
                            flex: 8,
                            child: DeliveryStrip(
                              sessionId: sessionId,
                              hostedOnTerminal: true,
                            ),
                          ),
                        ],
                        if (toggle != null) ...[
                          const SizedBox(width: Insets.sm),
                          toggle,
                        ],
                      ],
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget half(
      IconData icon,
      String label,
      String tip,
      bool selected,
      VoidCallback onTap,
    ) {
      final colour = selected ? scheme.primary : scheme.onSurfaceVariant;
      return Tooltip(
        message: tip,
        child: Semantics(
          button: true,
          selected: selected,
          label: tip,
          child: InkWell(
            onTap: onTap,
            child: Container(
              // Padded rather than fixed at 22px: the halves must grow with the
              // ambient text scale or the row loses its shared centre-line.
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: kBarControlPad,
              ),
              color: selected
                  ? scheme.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: Chrome.iconSmall, color: colour),
                  if (!compact) ...[
                    const SizedBox(width: Insets.xs),
                    Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colour,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    // No padding of its own: the bar spaces its own row. The border is on the
    // decoration, which reserves its pixel where a `ClipRRect` would not.
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          half(
            AppIcons.terminal,
            'Terminal',
            'Terminal view',
            onTerminal,
            onTerminalView,
          ),
          half(AppIcons.chatCircle, 'Chat', 'Chat view', !onTerminal, onChat),
        ],
      ),
    );
  }
}

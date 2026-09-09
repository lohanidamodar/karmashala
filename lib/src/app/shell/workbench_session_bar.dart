part of 'workbench.dart';

// The chrome under the surface: what belongs to the session on screen, the box
// that reserves its height across a switch, and the toggle between a session's
// two renderings.

/// The chrome under the surface: what belongs to the session on screen, on a
/// bar of its own.
///
/// The controls used to be split between the two ends of the window — the
/// permission chip up in the tab strip, the delivery actions loose under the
/// terminal on no surface at all. One rule instead: the strip is tabs, and this
/// is the session. It is built like the strip (the same rule, the same
/// [Chrome.tabStrip] floor, the same [ColorScheme.surfaceContainerLow]) so the
/// two read as the same kind of thing at either end of the work.
///
/// **What it speaks for is what is on screen.** That is the focused pane's
/// session — [activePaneSessionIdProvider], for the reason given there — not
/// the Explorer's selection, or switching terminal tabs would leave these
/// controls acting on a session the user is no longer looking at. The one
/// exception is [_NoPaneForSession]: no pane is on screen there at all, so the
/// session the bar is about is the selected one, which is also what keeps the
/// toggle — the only way to that session's transcript — from disappearing on
/// exactly the surface that offers nothing else.
///
/// While the conversation is up its composer already carries the permission
/// chip and the delivery strip, so the bar is down to the toggle rather than a
/// second copy of them.
///
/// **Two lines, not one flow.** A quiet [DeliveryStateLine] carrying what is
/// true — the stage, the branch, the counts — over one action row carrying what
/// can be done about it, with the permission control at its left end and the
/// view toggle at its right. Everything used to be poured into a single [Wrap],
/// which sorted itself by whatever fitted: the facts and the buttons ran
/// together at the same weight, `Commit` ended up stranded beside the branch
/// name a row above its three siblings, and the toggle — centred against a
/// two-row block — lined up with nothing. Grouping is the fix, and it is a
/// layout rather than a rule: facts cannot interleave with actions because they
/// are no longer in the same run.
///
/// The row is aligned to its **start** so that the two ends keep the action
/// row's own line when the actions wrap on a narrow window, instead of drifting
/// to the middle of a two-run block. Every control on the row is the same
/// height by construction (`kBarControlPad`), so aligning to the start and
/// aligning to the centre are the same thing while there is one run.
///
/// **The height is reserved across a session change.** Everything in this bar
/// that has any height is per-session and asynchronous, and
/// `sessionDeliveryProvider` is an `autoDispose` *family*: switching terminal
/// tabs switches the key, so — unlike the refresh `a01cd1f7` fixed — there is
/// no previous value to carry and the bar genuinely knows nothing about the
/// session it has just been handed. The facts line takes itself away, the
/// actions fold to the "could not tell" set and stop wrapping, the bar drops to
/// its floor, and the terminal above it is `Expanded`: it takes the pixels,
/// resizes its character grid and reflows. Then git and `gh` answer and all of
/// it happens again in reverse. Measured across one tab switch, before / while
/// reading / after:
///
/// | window | bar        | terminal rows | grid resizes |
/// |--------|------------|---------------|--------------|
/// | 1400px | 51 → 31 → 51 | 50 → 51 → 50 | 2 |
/// | 900px  | 79 → 57 → 79 | 48 → 49 → 48 | 2 |
/// | 800px  | 99 → 57 → 99 | 47 → 49 → 47 | 2 |
/// | 720px  | 127 → 57 → 127 | 45 → 49 → 45 | 2 |
///
/// — which is the owner's *"the terminal blinks when switching tabs"*, and at
/// the app's minimum window it is the same 70-odd pixels the focus blink cost.
///
/// So the bar keeps the height it last settled at until it has been told what
/// this session is ([_HeldHeight]). It is the *box* that is held, not the
/// content: the strip below draws this session's actions honestly and from the
/// first frame, and pressing one acts on this session. A reservation rather
/// than better data on purpose — it does not care *why* a child would take less
/// room this frame, so a fourth per-session control, a remount, or a provider
/// nobody has written yet all cost nothing.
///
/// The quota chip is that fourth control, and it happens to *shorten* the
/// reservation's work rather than lengthen it: it shares the facts line's row
/// and draws `usage …` from the first frame, so that row no longer collapses to
/// nothing while a session is being read. The reservation still covers the rest.
///
/// **What it cannot be is a constant.** The settled bar is 51px on a wide
/// window and 127px on the narrowest one the app supports, because the actions
/// legitimately wrap to three runs there — so a fixed height would either waste
/// 76px of terminal at 1400px or need somewhere else to put two thirds of the
/// delivery actions. That trade (one run, everything else behind an overflow,
/// like the tab strip's [TabPicker]) would make the bar genuinely rigid and is
/// the only thing that would also stop it growing when a *poll* changes the
/// action set; it is a redesign of the strip, not a fix to the blink, and it is
/// not taken here.
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

    // Whether the bar has been told what it is describing yet. Only "never had
    // an answer for *this* session" counts: a refresh keeps its previous value
    // (`a01cd1f7`) and moves nothing, and a read that failed has answered.
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
          // reservation instead of leaving the terminal showing through under
          // it.
          child: _HeldHeight(
            hold: reading,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Full width and above everything, so the facts read as a caption
                // over the row rather than as the first item in it.
                if (sessionId != null) ...[
                  Row(
                    children: [
                      Expanded(
                        // Scrolled rather than squeezed, for the reason the
                        // action row below gives: a group narrow enough that
                        // the branch name and the counts will not fit is one
                        // where sharing the pixels out leaves none of them
                        // legible. Its own `LayoutBuilder` because this line
                        // sits above the row that has the width class.
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
                      // **What this session's account has left, at the end of
                      // the line of facts** — because that is what it is. It
                      // came from the window's status bar, where one figure
                      // spoke for whichever session the app believed was
                      // focused; each pane now reads its own account, which is
                      // the whole of the owner's *"tied to session not app"*.
                      //
                      // In the facts line and not in the action row below it,
                      // deliberately. The actions over-offer (Loop 33) and
                      // wrap rather than shrink, so anything added beside them
                      // is paid for in runs: at 720px the row is already 14px
                      // over with the model chip squeezed to its glyphs, which
                      // is why that chip steps aside under ~820px. A quota is
                      // not a control and must not compete with `Run tests`,
                      // `Check this` and `Continue with…` for the same
                      // pixels — up here it cannot push them anywhere at any
                      // width, and it is legible at every one.
                      //
                      // Its own widget with its own subscription, so a quota
                      // moving — the most frequent change in this bar —
                      // repaints the chip and neither the facts beside it nor
                      // the actions under it.
                      // Flexible for the same reason the line beside it is:
                      // this row is as wide as a group, not as wide as the
                      // window, and neither half of it may push the other out.
                      Flexible(child: UsageChip(sessionId: sessionId)),
                    ],
                  ),
                  // Whatever this session has just been told, in this session's
                  // bar. Full width for the same reason, and directly over the
                  // chips that post it.
                  SessionNoticeLine(sessionId: sessionId),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    // Whether a third control fits beside the permission mode and
                    // the delivery actions. Measured rather than guessed: at
                    // 720px — the smallest window the app supports — the row is
                    // already 14px over with the model chip squeezed to its
                    // glyphs, and 23px over at the 1.3x text step. Scaled by the
                    // text step for the same reason: the two fixed controls grow
                    // with it and the room does not.
                    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                    final roomForModel = constraints.maxWidth > 820 * scale;
                    // **A group is a fraction of the window, and this bar was
                    // designed when it was the window.** At the 363px a two-way
                    // split leaves it ran 50px over; at the 143px a split beside
                    // a wide Explorer leaves, nothing that keeps its natural
                    // width can fit at all.
                    //
                    // What a narrow group gives up, in order:
                    //
                    // 1. **The model chip**, above — a fact the chat surface
                    //    repeats in full, so a narrow bar loses a shortcut
                    //    rather than a control.
                    // 2. **Words.** Every pill drops to its glyph and keeps its
                    //    tooltip and its semantics label, so a pointer and a
                    //    screen reader still get the verb.
                    // 3. **Nothing else.** The actions do not go into an
                    //    overflow menu: `Commit` is what most visits to this bar
                    //    are for, and two clicks away is worse than small.
                    //
                    // Below that the row **scrolls** rather than squeezing.
                    // Sharing out a box narrower than the controls gives every
                    // one of them a few pixels and makes all of them unusable;
                    // scrolling keeps each at the size it needs and every one
                    // reachable. It is also the answer this app already gives
                    // one level down — `PaneGroupStrip` scrolls its chips when a
                    // region is dragged below their width.
                    //
                    // The toggle stays **outside** the scroll: it is the only
                    // way back from the conversation, and a way home you have to
                    // find by scrolling is not one.
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
                                        // Unbounded, so the strip's `Wrap` lays
                                        // out in one run and the bar keeps one
                                        // height whatever it holds.
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
                          // Beside the permission chip because they are the same kind
                          // of fact: what *this* session runs under, changed from
                          // where the session is. It used to live in the window's
                          // status bar next to the account quota, which put a
                          // per-session control among window-wide ones and left it
                          // describing whichever session the app thought was focused.
                          // Flexible, and the only control here that is. The
                          // delivery actions do not shrink — they wrap to a second
                          // run, which is what put `Commit` a row above its own peers
                          // — and the permission mode is a fixed vocabulary. A model
                          // name is neither: it is the one label here whose width
                          // nobody can predict, so it is the one that gives way. One
                          // part against the strip's eight leaves it the ~118px it
                          // wants at the fullest bar without letting it push the
                          // actions onto a second run.
                          //
                          // Absent rather than crushed below that: the chat surface
                          // carries the same chip at full width, so a narrow terminal
                          // loses a shortcut, not the control.
                          if (roomForModel) ...[
                            Flexible(
                              child: SessionModelChip(
                                sessionId: sessionId,
                                maxLabelWidth: 72,
                              ),
                            ),
                            const SizedBox(width: Insets.sm),
                          ],
                          // The delivery actions take the room the other two do not:
                          // they are the part that has something new to say as the
                          // work moves, and the part that wraps when there is no room
                          // left. They wrap *within* this box, so a second run stays
                          // inside the group instead of pushing the ends around.
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

/// A box that keeps the height it last laid out at, while [hold] is set.
///
/// The [_SessionBar]'s reservation, and nothing more general than that: it does
/// not animate, it does not shrink-wrap, and it has no opinion about what its
/// child draws. While [hold] is set it is at least as tall as the last height
/// its child asked for while [hold] was *not* set; the child is still laid out
/// against the real constraints and still painted at the top, so a shorter
/// child leaves empty bar under itself rather than being stretched.
///
/// A render object rather than a `GlobalKey` and a post-frame measure, because
/// the frame that matters is the one the switch produces: measuring after the
/// fact would let the bar collapse for exactly the frame the reservation exists
/// to cover, and would cost a rebuild for every height it ever settles at.
///
/// The remembered height belongs to the **width** it was measured at — a
/// different width is a different wrapping question, and an answer from the old
/// one would be a guess. Dragging the window while a session is being read
/// therefore gets no reservation, which is right: a window resize is already
/// resizing the grid on purpose.
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

/// The two renderings of one session. Not a navigation control: both sides show
/// the same record, the same PTY and the same lifecycle.
///
/// Labelled in words as well as icons, and the only way to the conversation now
/// that no tab stands for it. The terminal is where a session opens, so the way
/// back to its transcript cannot be a chord and a hover — it has to be a thing
/// on the chrome that says what it is.
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

  /// Glyphs only, for a group too narrow to spell the two words.
  ///
  /// The labels are the first thing this control gives up and the icons are the
  /// last: a two-state switch between a terminal and a conversation is legible
  /// from its marks, the tooltip still says the words, and the semantics label
  /// is unchanged — so nothing is lost to a screen reader or to the keyboard.
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
              // Padded rather than fixed at 22px: the halves have to grow with
              // the ambient text scale like the permission control and the
              // actions beside them, or the row stops sharing a centre-line at
              // exactly the sizes an accessibility setting asks for.
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

    // No padding of its own: the bar spaces its own row, and a control whose
    // bounds include a margin is a control whose centre-line is a guess.
    //
    // A `Container` with the border on its decoration rather than a `ClipRRect`
    // over a `DecoratedBox`, because only the first *reserves* the border's
    // pixel: the second painted the outline inside the halves and left the
    // toggle two pixels shorter than the permission control and the actions,
    // which is one pixel of drift on the centre-line the row is built around.
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

// The peek's one row: its controls and what folds into its menu.
part of '../overview_peek.dart';

/// **The peek's one row** (owner, 2026-10-08), at every width: the agent, the
/// title — whole on hover or a long press once it is cut — then the views,
/// Stop or Resume, Open, ↑ ↓ and Pin, then ⋯ and ✕. On a phone, back leads
/// and ✕ goes. What the row has no room for folds into ⋯, Pin first, then
/// ↑ ↓, then Open, then Stop; the views, ⋯ and ✕ never fold. Archive,
/// Detach, the parent and — on a phone — the sub-sessions are always in ⋯.
/// The plan, when there is one, is under the row on a desktop.
class _PeekHeader extends ConsumerStatefulWidget {
  const _PeekHeader({
    required this.card,
    required this.views,
    required this.compact,
    required this.onClose,
    this.subSessions,
    this.onPeek,
    this.onPrevious,
    this.onNext,
  });

  final OverviewCard card;
  final Widget views;
  final bool compact;
  final ({String label, VoidCallback open})? subSessions;
  final VoidCallback onClose;
  final ValueChanged<OverviewCard>? onPeek;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  ConsumerState<_PeekHeader> createState() => _PeekHeaderState();
}

/// The row's controls that fold, in the row's order; the last folds first.
enum _PeekControl { stop, open, move, pin }

class _PeekHeaderState extends ConsumerState<_PeekHeader> {
  /// The controls the row last left out, offered in ⋯ instead.
  var _folded = const <_PeekControl>{};

  void _hiddenChanged(List<bool> hidden) {
    final folded = {
      for (var i = 0; i < hidden.length; i++)
        if (hidden[i]) _PeekControl.values[i],
    };
    if (!setEquals(folded, _folded)) setState(() => _folded = folded);
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final entry = card.entry;
    final id = entry.id;
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final native = entry.native;
    final live = native != null && sessionHasLiveProcess(ref, id);
    final resumable = watchOverviewResumable(ref, card);
    final pinned = ref.watch(
      overviewPrefsProvider.select((p) => p.pinned.contains(id)),
    );
    final plan = widget.compact
        ? null
        : ref.watch(overviewGlanceProvider(id)).asData?.value?.plan;
    final parentId = native?.parentSessionId;
    final parent = parentId == null
        ? null
        : overviewCardOf(ref.watch(overviewBoardProvider), parentId);
    final subSessions = widget.subSessions;
    final onPeek = widget.onPeek;
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
    );

    void stop() => endSessionFromRow(context, ref, id, title: entry.title);
    void resume() => resumeFromDashboard(context, ref, entry);
    void open() => openOverviewSession(context, ref, entry);
    void pin() => toggleOverviewPin(context, ref, id);

    // The peek's own verbs, ahead of the session menu every place has: what
    // folded off the row that the menu does not already hold (it has Open
    // and End), the sub-sessions on a phone, and the way to the parent.
    final extras = <String, (String, IconData, VoidCallback?)>{
      if (_folded.contains(_PeekControl.stop) && resumable)
        'resume': ('Resume', AppIcons.play, resume),
      if (subSessions != null)
        'subSessions': (
          subSessions.label,
          AppIcons.treeStructure,
          subSessions.open,
        ),
      if (_folded.contains(_PeekControl.pin))
        'pin': (pinned ? 'Unpin' : 'Pin to the top', AppIcons.pushPin, pin),
      if (_folded.contains(_PeekControl.move)) ...{
        'previous': ('Previous session', AppIcons.caretUp, widget.onPrevious),
        'next': ('Next session', AppIcons.caretDown, widget.onNext),
      },
      if (parent != null)
        'parent': (
          'Sub-session of ${parent.entry.title}',
          AppIcons.caretUp,
          onPeek == null ? null : () => onPeek(parent),
        ),
    };
    Future<void> more(BuildContext button) => showOverviewSessionMenu(
      button,
      ref,
      entry,
      extras: [
        for (final MapEntry(key: value, value: (label, icon, run))
            in extras.entries)
          DesktopMenuItem(
            key: ValueKey('overview-peek-menu:$value'),
            value: 'peek:$value',
            label: label,
            icon: icon,
            enabled: run != null,
          ),
      ],
      onExtra: (picked) async {
        if (!picked.startsWith('peek:')) return false;
        extras[picked.substring('peek:'.length)]?.$3?.call();
        return true;
      },
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Words beside Stop and Open while the peek is wide enough to spare
        // them; glyphs, each with its tooltip, below that.
        final labelled =
            !widget.compact &&
            constraints.maxWidth >=
                WidthClass.scaleBreakpoint(
                  _peekLabelsFrom,
                  MediaQuery.textScalerOf(context),
                );
        Widget verb({
          required Key key,
          required String label,
          required String tooltip,
          required IconData icon,
          required VoidCallback onPressed,
          bool tonal = false,
        }) {
          if (!labelled) {
            return IconButton(
              key: key,
              tooltip: tooltip,
              visualDensity: density.controlDensity,
              onPressed: onPressed,
              icon: Icon(icon),
            );
          }
          final style = TextButton.styleFrom(
            visualDensity: density.controlDensity,
            padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          );
          return Tooltip(
            message: tooltip,
            child: tonal
                ? FilledButton.tonalIcon(
                    key: key,
                    style: style,
                    onPressed: onPressed,
                    icon: Icon(icon, size: Chrome.iconSmall),
                    label: Text(label),
                  )
                : TextButton.icon(
                    key: key,
                    style: style,
                    onPressed: onPressed,
                    icon: Icon(icon, size: Chrome.iconSmall),
                    label: Text(label),
                  ),
          );
        }

        final controls = YieldingRow(
          yieldFromStart: false,
          keepsOne: false,
          onHiddenChanged: _hiddenChanged,
          children: [
            Row(
              key: const ValueKey('overview-peek-control:stop'),
              mainAxisSize: MainAxisSize.min,
              children: [
                OverviewResumingLabel(sessionId: id),
                if (resumable)
                  verb(
                    key: const ValueKey('overview-peek-resume'),
                    label: 'Resume',
                    tooltip: 'Resume this session',
                    icon: AppIcons.play,
                    onPressed: resume,
                    tonal: true,
                  )
                else if (live)
                  verb(
                    key: const ValueKey('overview-peek-stop'),
                    label: 'Stop',
                    tooltip: 'Stop the session',
                    icon: AppIcons.stop,
                    onPressed: stop,
                  ),
              ],
            ),
            KeyedSubtree(
              key: const ValueKey('overview-peek-control:open'),
              child: verb(
                key: const ValueKey('overview-peek-open'),
                label: 'Open',
                tooltip: 'Open in a tab',
                icon: AppIcons.arrowSquareOut,
                onPressed: open,
              ),
            ),
            Row(
              key: const ValueKey('overview-peek-control:move'),
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const ValueKey('overview-peek-previous'),
                  tooltip: 'Previous session (↑)',
                  visualDensity: density.controlDensity,
                  onPressed: widget.onPrevious,
                  icon: const Icon(AppIcons.caretUp),
                ),
                IconButton(
                  key: const ValueKey('overview-peek-next'),
                  tooltip: 'Next session (↓)',
                  visualDensity: density.controlDensity,
                  onPressed: widget.onNext,
                  icon: const Icon(AppIcons.caretDown),
                ),
              ],
            ),
            KeyedSubtree(
              key: const ValueKey('overview-peek-control:pin'),
              child: OverviewPinButton(sessionId: id),
            ),
          ],
        );

        final row = Row(
          children: [
            if (widget.compact)
              IconButton(
                key: const ValueKey('overview-peek-close'),
                tooltip: 'Back',
                visualDensity: VisualDensity.compact,
                onPressed: widget.onClose,
                icon: const Icon(AppIcons.arrowLeft),
              ),
            OverviewAgentRing(card: card),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: _PeekLine(
                titleFloor: overviewTitleFloor(
                  context,
                  entry.title,
                  titleStyle,
                ),
                children: [
                  TruncatedText(
                    entry.title,
                    key: const ValueKey('overview-peek-title'),
                    style: titleStyle,
                  ),
                  widget.views,
                  controls,
                ],
              ),
            ),
            Builder(
              builder: (button) => IconButton(
                key: const ValueKey('overview-peek-more'),
                tooltip: 'More',
                visualDensity: density.controlDensity,
                onPressed: () => more(button),
                icon: const Icon(AppIcons.dotsThreeVertical),
              ),
            ),
            if (!widget.compact)
              IconButton(
                key: const ValueKey('overview-peek-close'),
                tooltip: 'Close peek (Esc)',
                visualDensity: density.controlDensity,
                onPressed: widget.onClose,
                icon: const Icon(AppIcons.x),
              ),
          ],
        );
        return Padding(
          key: widget.compact ? const ValueKey('overview-peek-bar') : null,
          padding: widget.compact
              ? const EdgeInsets.symmetric(vertical: Insets.xxs)
              : const EdgeInsets.fromLTRB(
                  Insets.md,
                  Insets.xs,
                  Insets.xs,
                  Insets.xs,
                ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row,
              // Other live sessions writing in its checkout; nothing if none.
              if (native != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SharedCheckoutBadge(sessionId: id),
                ),
              if (plan != null && plan.total > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    0,
                    Insets.xs,
                    Insets.sm,
                    Insets.xs,
                  ),
                  child: OverviewPlanLine(plan: plan),
                ),
            ],
          ),
        );
      },
    );
  }
}

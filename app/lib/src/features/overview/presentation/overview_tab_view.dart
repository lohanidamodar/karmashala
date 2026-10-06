import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import 'overview_board_view.dart';
import 'overview_filters.dart';
import 'overview_peek.dart';
import 'overview_strip.dart';
import 'overview_timeline_view.dart';

/// **The Overview tab**: what is going on across all the work, as a Board
/// (state by project or machine) or a Timeline. Built only while its tab is
/// on screen; on the phone it is a page under More.
class OverviewTabView extends ConsumerWidget {
  const OverviewTabView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final view = ref.watch(overviewPrefsProvider.select((p) => p.view));
    // Under a page that already names it (the phone's More), no second title.
    final untitled = PaneTitleOverride.maybeOf(context) != null;
    final switcher = _ViewSwitcher(
      view: view,
      onChanged: ref.read(overviewPrefsProvider.notifier).setView,
    );
    final body = switch (view) {
      OverviewView.board => const _BoardBody(),
      OverviewView.timeline => const OverviewTimelineView(),
    };
    return Scaffold(
      appBar: untitled
          ? null
          : AppBar(
              toolbarHeight: 44,
              // A workbench tab: an implied back button would pop the app's
              // route.
              automaticallyImplyLeading: false,
              title: Row(
                children: [
                  Icon(AppIcons.squaresFour, color: theme.colorScheme.tertiary),
                  const SizedBox(width: Insets.sm),
                  const Flexible(
                    child: Text(
                      'Overview',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: Insets.lg),
                  switcher,
                ],
              ),
            ),
      body: untitled
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.lg,
                    Insets.sm,
                    Insets.lg,
                    0,
                  ),
                  child: switcher,
                ),
                Expanded(child: body),
              ],
            )
          : body,
    );
  }
}

/// [Board] [Timeline].
class _ViewSwitcher extends StatelessWidget {
  const _ViewSwitcher({required this.view, required this.onChanged});

  final OverviewView view;
  final ValueChanged<OverviewView> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<OverviewView>(
    key: const ValueKey('overview-view'),
    showSelectedIcon: false,
    style: const ButtonStyle(visualDensity: VisualDensity.compact),
    segments: const [
      ButtonSegment(value: OverviewView.board, label: Text('Board')),
      ButtonSegment(value: OverviewView.timeline, label: Text('Timeline')),
    ],
    selected: {view},
    onSelectionChanged: (picked) => onChanged(picked.single),
  );
}

/// Below this pane width four columns do not fit, and the Board is a list
/// grouped by state, as on the phone.
const double kOverviewBoardMinWidth = 720;

/// The docked peek's width.
const double _peekWidth = 340;

/// The filters, the strip, then the Board (or its list) with the peek beside
/// it — or, narrow, in a sheet. Arrows move between cards, Enter peeks, Esc
/// closes the peek.
class _BoardBody extends ConsumerStatefulWidget {
  const _BoardBody();

  @override
  ConsumerState<_BoardBody> createState() => _BoardBodyState();
}

class _BoardBodyState extends ConsumerState<_BoardBody> {
  final _focus = FocusNode(debugLabel: 'overview-board');
  var _docks = true;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _open(OverviewCard card) {
    _focus.requestFocus();
    final focus = ref.read(overviewFocusProvider.notifier);
    if (_docks) {
      focus.peek(card.id);
      return;
    }
    focus.select(card.id);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => FractionallySizedBox(
        heightFactor: 0.7,
        child: Consumer(
          builder: (context, ref, _) {
            final live = overviewCardOf(
              ref.watch(overviewBoardProvider),
              card.id,
            );
            return OverviewPeek(
              card: live ?? card,
              onClose: () => Navigator.of(sheet).pop(),
            );
          },
        ),
      ),
    );
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final focus = ref.read(overviewFocusProvider);
    final controller = ref.read(overviewFocusProvider.notifier);
    final move = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => BoardMove.up,
      LogicalKeyboardKey.arrowDown => BoardMove.down,
      LogicalKeyboardKey.arrowLeft => BoardMove.left,
      LogicalKeyboardKey.arrowRight => BoardMove.right,
      _ => null,
    };
    if (move != null) {
      final grid = drawnGrid(
        ref.read(overviewBoardProvider),
        ref.read(overviewFoldsProvider),
      );
      controller.select(moveOnBoard(grid, focus.selected, move));
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final card = overviewCardOf(
        ref.read(overviewBoardProvider),
        focus.selected,
      );
      if (card == null) return KeyEventResult.ignored;
      _open(card);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (focus.peeked != null) {
        controller.closePeek();
      } else if (focus.selected != null) {
        controller.select(null);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= kOverviewBoardMinWidth;
      _docks = constraints.maxWidth >= kOverviewBoardMinWidth + _peekWidth;
      final peeked = _docks
          ? overviewCardOf(
              ref.watch(overviewBoardProvider),
              ref.watch(overviewFocusProvider.select((f) => f.peeked)),
            )
          : null;
      final gutter = constraints.maxWidth < 560 ? Insets.lg : Insets.xl;
      final main = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, Insets.sm, gutter, 0),
            child: const OverviewFilterBar(),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, Insets.xs, gutter, Insets.sm),
            child: const OverviewStripBar(),
          ),
          const Divider(height: 1),
          Expanded(
            child: wide
                ? OverviewBoardView(onOpen: _open)
                : OverviewListView(onOpen: _open),
          ),
        ],
      );
      return Focus(
        focusNode: _focus,
        onKeyEvent: _key,
        child: peeked == null
            ? main
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: main),
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: _peekWidth,
                    child: OverviewPeek(
                      key: ValueKey('overview-peek:${peeked.id}'),
                      card: peeked,
                      onClose: ref
                          .read(overviewFocusProvider.notifier)
                          .closePeek,
                    ),
                  ),
                ],
              ),
      );
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../../app/shell/phone_shell.dart' show phoneWorkbenchOpener;
import '../../explorer/application/explorer_actions.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart';
import 'overview_filters.dart';
import 'overview_hybrid.dart';
import 'overview_peek.dart';
import '../timeline/presentation/overview_timeline_view.dart';

/// **The Overview tab**: what is going on across all the work, as a Board
/// (state by project or machine) or a Timeline. Built only while its tab is
/// on screen; on the phone it is a page under More.
class OverviewTabView extends ConsumerWidget {
  const OverviewTabView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(overviewPrefsProvider.select((p) => p.view));
    return WorkbenchTabScaffold(
      icon: AppIcons.squaresFour,
      title: 'Overview',
      controls: [
        CompactSegmented<OverviewView>(
          key: const ValueKey('overview-view'),
          segments: const [
            ButtonSegment(value: OverviewView.board, label: Text('Board')),
            ButtonSegment(
              value: OverviewView.timeline,
              label: Text('Timeline'),
            ),
          ],
          selected: view,
          onChanged: ref.read(overviewPrefsProvider.notifier).setView,
        ),
      ],
      actions: [
        if (view == OverviewView.board) const OverviewFilterButton(),
      ],
      body: switch (view) {
        OverviewView.board => const _BoardBody(),
        OverviewView.timeline => const _TimelineBody(),
      },
    );
  }
}

/// Whether the keyboard is in a text field.
bool overviewTyping() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>() !=
    null;

/// The least width mission control keeps beside a docked peek.
const double kOverviewBoardMinWidth = 720;

/// The docked peek's width.
const double _peekWidth = 340;

/// The Timeline, opening a bar's session as the Board does. Its log outlives
/// the sessions it draws, so a bar can name one that has since been deleted:
/// that is said, not treated as a failure.
class _TimelineBody extends ConsumerWidget {
  const _TimelineBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) => OverviewTimelineView(
    onOpenSession: (id) => openTimelineSession(context, ref, id),
  );
}

/// Opens session [id] from the Timeline: its tab when the row is still here,
/// otherwise a line saying it was deleted and its history stays.
Future<void> openTimelineSession(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final showWorkbench = phoneWorkbenchOpener(context, ref);
  final actions = ref.read(explorerActionsProvider);
  final imported = ref.read(importedSessionsProvider).getById(id);
  final ExplorerResult result;
  if (ref.read(sessionsDataProvider).getById(id) != null) {
    result = await actions.openNative(id);
  } else if (imported != null) {
    result = await actions.openImported(imported);
  } else {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text(
          'That session was deleted. Its history stays on the Timeline.',
        ),
      ),
    );
    return;
  }
  if (!result.isFailure) showWorkbench?.call();
  final message = result.message;
  if (message != null) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Mission control with the peek docked beside it, or in a sheet where it
/// would crowd. Arrows move between marks, Enter peeks, Esc closes the peek.
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

  void _open(OverviewCard card, {bool editing = false}) {
    _focus.requestFocus();
    final focus = ref.read(overviewFocusProvider.notifier);
    if (_docks) {
      focus.peek(card.id, editing: editing);
      return;
    }
    editing ? focus.peek(card.id, editing: true) : focus.select(card.id);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => FractionallySizedBox(
        heightFactor: 0.85,
        child: Consumer(
          builder: (context, ref, _) {
            final live = overviewCardOf(
              ref.watch(overviewBoardProvider),
              card.id,
            );
            return OverviewPeek(
              card: live ?? card,
              onClose: () => Navigator.of(sheet).pop(),
              onPeek: (child) {
                Navigator.of(sheet).pop();
                _open(child);
              },
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
    // A key a text field let through is still the field's, never the Board's.
    if (overviewTyping()) return KeyEventResult.ignored;
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
      final marks = overviewDrawnCards(
        overviewSectionsOf(
          ref.read(overviewBoardProvider),
          waitingSince: (id) =>
              ref.read(sessionStatusLookupProvider)(id)?.waitingSince,
        ),
      );
      controller.select(moveOnTiles(marks, focus.selected, move));
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
      _docks = constraints.maxWidth >= kOverviewBoardMinWidth + _peekWidth;
      final peeked = _docks
          ? overviewCardOf(
              ref.watch(overviewBoardProvider),
              ref.watch(overviewFocusProvider.select((f) => f.peeked)),
            )
          : null;
      final main = OverviewHybrid(
        onOpen: _open,
        onEdit: (card) => _open(card, editing: true),
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
                      onPeek: _open,
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

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart' show phoneWorkbenchOpener;
import '../../explorer/application/explorer_actions.dart';
import '../../sessions/application/session_chat_source.dart'
    show composersHoldingTextProvider;
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../application/overview_batch.dart';
import '../application/overview_board.dart';
import '../application/overview_on_screen.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart';
import 'overview_batch_bar.dart';
import 'overview_filters.dart';
import 'overview_hybrid.dart';
import 'overview_peek.dart';
import 'overview_pins.dart';
import 'overview_queue_card.dart';
import 'overview_resume_picker.dart';
import 'overview_triage.dart';
import '../../sessions/presentation/new_session_dialog.dart';
import '../../sessions/presentation/approval_request_card.dart';
import '../../sessions/presentation/prompt_cards/question_prompt_card.dart';
import '../timeline/presentation/overview_timeline_view.dart';

/// **The Overview tab**: what is going on across all the work, as a Board
/// (state by project or machine) or a Timeline. Built only while its tab is
/// on screen; on the phone it is a page under More.
class OverviewTabView extends ConsumerWidget {
  const OverviewTabView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(overviewPrefsProvider.select((p) => p.view));
    return _OnScreen(
      child: WorkbenchTabScaffold(
        icon: AppIcons.squaresFour,
        title: 'Agent dashboard',
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
          const _ResumeButton(),
          const _NewSessionButton(),
          if (view == OverviewView.board) ...[
            const OverviewFilterButton(),
            // The keys need a keyboard; a thumb has none to press.
            if (!UiDensity.of(context).isTouch)
              IconButton(
                key: const ValueKey('overview-keys-button'),
                tooltip: 'Keyboard shortcuts (?)',
                onPressed: () => showOverviewKeys(context),
                icon: const Icon(AppIcons.keyboard),
              ),
          ],
        ],
        body: switch (view) {
          OverviewView.board => const _BoardBody(),
          OverviewView.timeline => const _TimelineBody(),
        },
      ),
    );
  }
}

/// Counts the dashboard as drawn while it is, for the chime to hold back:
/// what is in front of the person needs no sound.
class _OnScreen extends ConsumerStatefulWidget {
  const _OnScreen({required this.child});

  final Widget child;

  @override
  ConsumerState<_OnScreen> createState() => _OnScreenState();
}

class _OnScreenState extends ConsumerState<_OnScreen> {
  late final OverviewOnScreen _shown;
  var _counted = false;

  @override
  void initState() {
    super.initState();
    _shown = ref.read(overviewOnScreenProvider.notifier);
    // After the frame: a provider is not changed while the tree builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shown.add();
      _counted = true;
    });
  }

  @override
  void dispose() {
    if (_counted) {
      final shown = _shown;
      Future.microtask(shown.remove);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// **Resume…**: a stopped or ended session brought back from here, kept on
/// the dashboard unless the person unticks it, which this device remembers.
class _ResumeButton extends ConsumerWidget {
  const _ResumeButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void resume() => unawaited(showOverviewResume(context, ref));
    final narrow = MediaQuery.sizeOf(context).width < WidthClass.mediumMin;
    return narrow
        ? IconButton(
            key: const ValueKey('overview-resume'),
            tooltip: 'Resume… (R)',
            onPressed: resume,
            icon: const Icon(AppIcons.clockCounterClockwise),
          )
        : Tooltip(
            message: 'Resume a stopped or ended session (R)',
            child: TextButton.icon(
              key: const ValueKey('overview-resume'),
              onPressed: resume,
              icon: const Icon(AppIcons.clockCounterClockwise),
              label: const Text('Resume…'),
            ),
          );
  }
}

/// **New session**, from here: the app's own dialog, in chat form where the
/// agent has one, kept here — started at the server, no tab, its card picked
/// and peeked — unless the person unticks it, which this device remembers.
class _NewSessionButton extends ConsumerWidget {
  const _NewSessionButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void start() {
      final prefs = ref.read(overviewPrefsProvider.notifier);
      final focus = ref.read(overviewFocusProvider.notifier);
      unawaited(
        NewSessionDialog.show(
          context,
          // Ticked as the background setting says; unticking is for this
          // start only.
          keepHere: ref.read(launchInBackgroundProvider),
          preferChat: true,
          onStarted: (session, {required keptHere}) {
            if (keptHere) {
              prefs.setView(OverviewView.board);
              focus.peek(session.id);
            }
          },
        ),
      );
    }

    final narrow = MediaQuery.sizeOf(context).width < WidthClass.mediumMin;
    return narrow
        ? IconButton(
            key: const ValueKey('overview-new-session'),
            tooltip: 'New session',
            onPressed: start,
            icon: const Icon(AppIcons.plus),
          )
        : TextButton.icon(
            key: const ValueKey('overview-new-session'),
            onPressed: start,
            icon: const Icon(AppIcons.plus),
            label: const Text('New session'),
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

/// From this width the peek docks beside the board, resizable; below it, it
/// floats over the board so the cards keep their columns.
const double kOverviewPeekDocksFrom = 1280;

/// The peek's width when it opens, and the bounds a drag keeps it in.
const double kOverviewPeekWidth = 520;
const double _peekMinWidth = 360;
const double _peekMaxWidth = 820;

/// How the peek sits beside the board at a width.
enum OverviewPeekMode { docked, overlay, sheet }

/// The peek's place at [width]: a full-screen sheet on a phone, over the
/// board below [kOverviewPeekDocksFrom], docked from it.
OverviewPeekMode overviewPeekModeAt(double width) =>
    width < WidthClass.mediumMin
    ? OverviewPeekMode.sheet
    : width < kOverviewPeekDocksFrom
    ? OverviewPeekMode.overlay
    : OverviewPeekMode.docked;

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
/// would crowd, triaged from the keyboard ([overviewTriageShortcuts]).
class _BoardBody extends ConsumerStatefulWidget {
  const _BoardBody();

  @override
  ConsumerState<_BoardBody> createState() => _BoardBodyState();
}

class _BoardBodyState extends ConsumerState<_BoardBody> {
  final _focus = FocusNode(debugLabel: 'overview-board');
  final _questions = <String, QuestionPromptController>{};
  var _mode = OverviewPeekMode.docked;
  var _peekWidth = kOverviewPeekWidth;

  bool get _inSheet => _mode == OverviewPeekMode.sheet;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// The ids ↑ and ↓ walk, as drawn.
  List<String> _order() {
    final sections = _sections();
    return [
      for (final card in [
        ...sections.queue,
        ...sections.work,
        ...sections.ready,
      ])
        card.id,
    ];
  }

  /// The session [step] places from [id] in [_order], or null past an end.
  String? _stepFrom(String id, int step) {
    final order = _order();
    final at = order.indexOf(id);
    final next = at + step;
    return at < 0 || next < 0 || next >= order.length ? null : order[next];
  }

  QuestionPromptController _questionOf(String id) =>
      _questions.putIfAbsent(id, QuestionPromptController.new);

  OverviewSections _sections() => overviewSectionsOf(
    ref.read(overviewBoardProvider),
    waitingSince: (id) =>
        ref.read(sessionStatusLookupProvider)(id)?.waitingSince,
  );

  void _open(
    OverviewCard card, {
    bool editing = false,
    OverviewPeekTab tab = OverviewPeekTab.chat,
  }) {
    ref
        .read(overviewFocusProvider.notifier)
        .peek(card.id, editing: editing, tab: tab);
    if (!_inSheet) {
      _focus.requestFocus();
      return;
    }
    _showSheet(card);
  }

  var _sheetOpen = false;

  /// A peek asked for from outside the board — New session's — before its
  /// card was on the board, for the phone's sheet to open on once it is.
  String? _pendingSheet;

  /// The phone's peek: one sheet at a time, following the peeked session, so
  /// a sub-session opened from it replaces what it shows.
  void _showSheet(OverviewCard card) {
    if (_sheetOpen) return;
    _sheetOpen = true;
    // A page of its own, not a sheet: a sheet's handle and header took 40%
    // of a phone before any chat (owner, 2026-10-08).
    unawaited(
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute(
              builder: (page) => Scaffold(
                body: SafeArea(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final board = ref.watch(overviewBoardProvider);
                      final id = ref.watch(
                        overviewFocusProvider.select((f) => f.peeked),
                      );
                      final live = overviewCardOf(board, id) ?? card;
                      final previous = _stepFrom(live.id, -1);
                      final next = _stepFrom(live.id, 1);
                      return OverviewPeek(
                        key: ValueKey('overview-peek:${live.id}'),
                        card: live,
                        compact: true,
                        onClose: () => Navigator.of(page).pop(),
                        onPeek: _open,
                        onPrevious: previous == null
                            ? null
                            : () => _goTo(previous),
                        onNext: next == null ? null : () => _goTo(next),
                      );
                    },
                  ),
                ),
              ),
            ),
          )
          .whenComplete(() {
            _sheetOpen = false;
            if (mounted) ref.read(overviewFocusProvider.notifier).closePeek();
          }),
    );
  }

  /// Opens the phone's sheet for a peek asked for from outside the board.
  void _followPeek(String? id) {
    if (id == null || !_inSheet || _sheetOpen) return;
    final card = overviewCardOf(ref.read(overviewBoardProvider), id);
    if (card == null) {
      _pendingSheet = id;
      return;
    }
    _pendingSheet = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showSheet(card);
    });
  }

  /// Shows [id]: in the peek when one is open, else as the selection.
  void _goTo(String id) {
    final focus = ref.read(overviewFocusProvider);
    final card = overviewCardOf(ref.read(overviewBoardProvider), id);
    if (card != null && focus.peeked != null) {
      _open(card);
    } else {
      ref.read(overviewFocusProvider.notifier).select(id);
    }
  }

  /// The waiting item after [from], round the queue; null when none other.
  String? _nextWaiting(String? from) {
    final queue = [for (final card in _sections().queue) card.id];
    final others = [
      for (final id in queue)
        if (id != from) id,
    ];
    if (others.isEmpty) return null;
    final at = queue.indexOf(from ?? '');
    if (at < 0) return others.first;
    for (var i = 1; i <= queue.length; i++) {
      final id = queue[(at + i) % queue.length];
      if (id != from) return id;
    }
    return others.first;
  }

  /// After [card] was answered, the next waiting item is selected by itself.
  void _advance(OverviewCard card) {
    final next = _nextWaiting(card.id);
    if (next != null) {
      _goTo(next);
      return;
    }
    final controller = ref.read(overviewFocusProvider.notifier);
    if (ref.read(overviewFocusProvider).peeked == card.id) {
      controller.closePeek();
    }
    controller.select(null);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Nothing else is waiting on you')),
    );
  }

  /// The selected card when it waits on you.
  OverviewCard? _target() {
    final selected = ref.read(overviewFocusProvider).selected;
    for (final card in _sections().queue) {
      if (card.id == selected) return card;
    }
    return null;
  }

  /// The session's terminal: the peek's Terminal tab where this machine
  /// hosts it, else the workbench's.
  void _terminal(OverviewCard card) {
    if (ref.read(overviewSessionPaneProvider(card.id)) != null) {
      _open(card, tab: OverviewPeekTab.terminal);
    } else {
      openSessionTerminal(ref, card.id);
    }
  }

  Map<Type, Action<Intent>> get _actions => {
    OverviewNextWaitingIntent: _Triage<OverviewNextWaitingIntent>((_) {
      final focus = ref.read(overviewFocusProvider);
      final next = _nextWaiting(focus.peeked ?? focus.selected);
      final current = focus.peeked ?? focus.selected;
      final queue = [for (final card in _sections().queue) card.id];
      if (next == null && queue.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Nothing is waiting on you')),
        );
        return;
      }
      _goTo(next ?? current!);
    }),
    OverviewPickOptionIntent: _Triage<OverviewPickOptionIntent>(
      (intent) => _questions[_target()?.id]?.pick(intent.number - 1),
      enabled: (_) => _questions[_target()?.id] != null,
    ),
    OverviewSendIntent: _Triage<OverviewSendIntent>((_) {
      final target = _target();
      if (target != null && (_questions[target.id]?.send() ?? false)) {
        _advance(target);
        return;
      }
      final selected = overviewCardOf(
        ref.read(overviewBoardProvider),
        ref.read(overviewFocusProvider).selected,
      );
      if (selected != null) _open(selected);
    }, enabled: (_) => ref.read(overviewFocusProvider).selected != null),
    OverviewApproveIntent: _Triage<OverviewApproveIntent>(
      (intent) async {
        final target = _target()!;
        final messenger = ScaffoldMessenger.maybeOf(context);
        final refused = await answerBoardApproval(
          ref,
          target.id,
          intent.answer,
        );
        if (!mounted) return;
        if (refused != null) {
          messenger?.showSnackBar(SnackBar(content: Text(refused)));
        } else {
          _advance(target);
        }
      },
      enabled: (intent) => switch (_target()) {
        final target? => boardApprovalOffers(
          ref,
          target.id,
        ).contains(intent.answer),
        null => false,
      },
    ),
    OverviewTerminalIntent: _Triage<OverviewTerminalIntent>(
      (_) => _terminal(_target()!),
      enabled: (_) => switch (_target()) {
        final target? =>
          overviewAskKind(
                target,
                ref.read(sessionStatusLookupProvider)(target.id),
              ) ==
              OverviewAskKind.terminalOnly,
        null => false,
      },
    ),
    OverviewMoveIntent: _Triage<OverviewMoveIntent>((intent) {
      final sections = _sections();
      final order = [
        for (final card in [
          ...sections.queue,
          ...sections.work,
          ...sections.ready,
        ])
          card.id,
      ];
      if (order.isEmpty) return;
      final focus = ref.read(overviewFocusProvider);
      final at = order.indexOf(focus.peeked ?? focus.selected ?? '');
      final next = at < 0
          ? 0
          : (at + (intent.down ? 1 : -1)).clamp(0, order.length - 1);
      _goTo(order[next]);
    }),
    OverviewDismissIntent: _Triage<OverviewDismissIntent>(
      (_) {
        if (!ref.read(overviewSelectionProvider).isEmpty) {
          ref.read(overviewSelectionProvider.notifier).clear();
          return;
        }
        final focus = ref.read(overviewFocusProvider);
        final controller = ref.read(overviewFocusProvider.notifier);
        focus.peeked != null ? controller.closePeek() : controller.select(null);
      },
      enabled: (_) {
        final focus = ref.read(overviewFocusProvider);
        return focus.peeked != null ||
            focus.selected != null ||
            !ref.read(overviewSelectionProvider).isEmpty;
      },
    ),
    OverviewShowKeysIntent: _Triage<OverviewShowKeysIntent>(
      (_) => showOverviewKeys(context),
    ),
    OverviewResumeIntent: _Triage<OverviewResumeIntent>(
      (_) => unawaited(showOverviewResume(context, ref)),
    ),
  };

  @override
  Widget build(BuildContext context) {
    ref.listen(overviewFocusProvider.select((f) => f.peeked), (_, next) {
      _followPeek(next);
      // A peek opened from outside the board — New session — hands the
      // board the keys, so N, 1–9 and Y work on it at once.
      if (next != null && !_inSheet && !overviewTyping()) {
        _focus.requestFocus();
      }
    });
    if (_pendingSheet case final id?) {
      ref.watch(overviewBoardProvider);
      _followPeek(id);
    }
    return _laidOut();
  }

  /// Two live chats docked together beside the board, the board giving way
  /// when it would be narrower than a peek.
  Widget _sideBySide(
    double width,
    Widget main,
    Widget first,
    OverviewCard second,
  ) {
    final focus = ref.read(overviewFocusProvider.notifier);
    final double each = ((width - kOverviewBoardMinWidth) / 2).clamp(
      _peekMinWidth,
      _peekMaxWidth,
    );
    final board = width - each * 2 >= _peekMinWidth;
    final secondPeek = OverviewPeek(
      key: ValueKey('overview-peek-beside:${second.id}'),
      card: second,
      beside: true,
      onPeek: _open,
      onClose: focus.closeBeside,
    );
    const divider = VerticalDivider(width: Insets.xs + Insets.hair);
    return Row(
      key: const ValueKey('overview-side-by-side-peeks'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (board) ...[
          Expanded(child: main),
          divider,
          SizedBox(width: each, child: first),
          divider,
          SizedBox(width: each, child: secondPeek),
        ] else ...[
          Expanded(child: first),
          divider,
          Expanded(child: secondPeek),
        ],
      ],
    );
  }

  /// The board's space clicked: the peek — both, side by side — closes,
  /// unless a box in it holds a message not yet sent. Closing would keep it
  /// (the draft is parked per session), but a stray click is not taken as
  /// leaving it.
  void _closePeekFromBoard() {
    final focus = ref.read(overviewFocusProvider);
    final holding = ref.read(composersHoldingTextProvider);
    if (holding.contains(focus.peeked) || holding.contains(focus.beside)) {
      return;
    }
    ref.read(overviewFocusProvider.notifier).closePeek();
  }

  Widget _laidOut() => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      _mode = overviewPeekModeAt(width);
      final peeked = _inSheet
          ? null
          : overviewCardOf(
              ref.watch(overviewBoardProvider),
              ref.watch(overviewFocusProvider.select((f) => f.peeked)),
            );
      final main = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OverviewBatchBar(),
          Expanded(
            // A click on the board's own space closes the peek, as Esc does.
            // A card, a button or a field clicked wins the tap — the
            // innermost recognizer does — so a card still switches the peek.
            child: GestureDetector(
              key: const ValueKey('overview-board-space'),
              behavior: HitTestBehavior.translucent,
              onTap: peeked == null ? null : _closePeekFromBoard,
              child: OverviewHybrid(
                onOpen: _open,
                onEdit: (card) => _open(card, editing: true),
                onTerminal: _terminal,
                onAnswered: _advance,
                questionControllerOf: _questionOf,
              ),
            ),
          ),
        ],
      );
      Widget? peek;
      if (peeked != null) {
        final previous = _stepFrom(peeked.id, -1);
        final next = _stepFrom(peeked.id, 1);
        peek = OverviewPeek(
          key: ValueKey('overview-peek:${peeked.id}'),
          card: peeked,
          onPeek: _open,
          onPrevious: previous == null ? null : () => _goTo(previous),
          onNext: next == null ? null : () => _goTo(next),
          onClose: ref.read(overviewFocusProvider.notifier).closePeek,
        );
      }
      final double peekWidth = _mode == OverviewPeekMode.docked
          ? _peekWidth.clamp(
              _peekMinWidth,
              math.max(
                _peekMinWidth,
                math.min(_peekMaxWidth, width - kOverviewBoardMinWidth),
              ),
            )
          : math.min(kOverviewPeekWidth, width);
      // A second peek only where two fit; narrower, the first stays alone.
      final beside =
          peek == null ||
              _mode != OverviewPeekMode.docked ||
              !overviewSideBySideFits(context)
          ? null
          : overviewCardOf(
              ref.watch(overviewBoardProvider),
              ref.watch(overviewFocusProvider.select((f) => f.beside)),
            );
      final Widget laidOut = switch ((peek, _mode)) {
        (null, _) => main,
        (final peek?, OverviewPeekMode.docked) when beside != null =>
          _sideBySide(width, main, peek, beside),
        (final peek?, OverviewPeekMode.docked) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: main),
            _PeekResizer(
              onDrag: (dx) => setState(
                () => _peekWidth = (peekWidth - dx).clamp(
                  _peekMinWidth,
                  _peekMaxWidth,
                ),
              ),
            ),
            SizedBox(width: peekWidth, child: peek),
          ],
        ),
        (final peek?, _) => Stack(
          children: [
            Positioned.fill(child: main),
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              width: peekWidth,
              child: Material(
                key: const ValueKey('overview-peek-overlay'),
                elevation: Elevations.popup,
                shadowColor: Theme.of(context).colorScheme.shadow,
                child: peek,
              ),
            ),
          ],
        ),
      };
      return Shortcuts(
        shortcuts: overviewTriageShortcuts,
        child: Actions(
          actions: _actions,
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            // A click anywhere on the board gives it the keys, unless a field
            // has them; a field or a terminal clicked takes them back after.
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                if (!overviewTyping()) _focus.requestFocus();
              },
              child: laidOut,
            ),
          ),
        ),
      );
    },
  );
}

/// The docked peek's edge, dragged to resize it.
class _PeekResizer extends StatelessWidget {
  const _PeekResizer({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      key: const ValueKey('overview-peek-resizer'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
      child: const SizedBox(
        width: Insets.xs + Insets.hair,
        child: VerticalDivider(width: Insets.xs + Insets.hair),
      ),
    ),
  );
}

/// One of the board's keys: never while a field is typed into, and only
/// where [enabled] says it applies, so an inapplicable key goes on its way.
class _Triage<T extends Intent> extends Action<T> {
  _Triage(this.run, {this.enabled});

  final void Function(T intent) run;
  final bool Function(T intent)? enabled;

  @override
  bool isEnabled(T intent) =>
      !overviewTyping() && (enabled?.call(intent) ?? true);

  @override
  Object? invoke(T intent) {
    run(intent);
    return null;
  }
}

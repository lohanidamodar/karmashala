// Mission control with its peek, its resizer and its triage keys.
part of '../overview_tab_view.dart';

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

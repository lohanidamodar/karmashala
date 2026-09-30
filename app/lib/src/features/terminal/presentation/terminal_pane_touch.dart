// **A pane at touch density** (Stage 2 step 9): drawn at the session's grid
// and panned, pinched to this device's own font size, a tap on a link
// confirmed in a sheet, and a selection's actions in a bar. A `part` because
// `_TerminalPaneViewState` is private.

part of 'terminal_pane_view.dart';

/// The longest press that is still a tap on a link, or one finger of a
/// two-finger tap.
const _tapTimeout = Duration(milliseconds: 300);

/// Two two-finger taps this close together fit the session's width.
const _twoFingerDoubleTap = Duration(milliseconds: 400);

/// A phone's terminal size until a pinch sets its own: the desktop's shared
/// size drew about twenty columns across a phone.
const double kPhoneTerminalFontSize = 10;

/// The grid's padding on both sides, as [TerminalView] is given it.
const double _gridInset = Insets.sm * 2;

extension _TouchPane on _TerminalPaneViewState {
  HostTerminalInstance? get _host {
    final instance = widget.instance;
    return instance is HostTerminalInstance ? instance : null;
  }

  double get _touchFontSize =>
      ref.read(deviceTerminalFontSizeProvider) ?? kPhoneTerminalFontSize;

  /// One cell at [fontSize], measured as the grid's painter measures it, so
  /// the pan's width and the view's grid agree with what is drawn.
  Size _cellSizeFor(double fontSize) {
    final cached = _cellSize;
    if (cached != null && cached.$1 == fontSize) return cached.$2;
    final painter = TerminalPainter(
      theme: widget.terminalTheme,
      textStyle: TerminalStyle(fontSize: fontSize, fontFamily: kMonoFamily),
      textScaler: TextScaler.noScaling,
    );
    final size = painter.cellSize;
    painter.dispose();
    _cellSize = (fontSize, size);
    return size;
  }

  /// The owner's rule (2026-09-30): a phone that shows a session's terminal
  /// fits the session to its width while it is on it, so nothing scrolls
  /// sideways; the desktop takes the width back when it types. Once per
  /// showing, and only on screen — a terminal kept behind the chat face does
  /// not take the session. "Back to the session's size" in the size chip
  /// holds for the rest of that showing.
  void _fitToPhoneOnShow({required bool atSessionGrid}) {
    final visible = Visibility.of(context);
    if (!visible) {
      _phoneFitted = false;
      return;
    }
    final host = _host;
    if (_phoneFitted || !atSessionGrid || host == null) return;
    // Measured, and linked: presence arrives once the attach is answered.
    if (host.viewGrid == null || host.presence.value == null) return;
    _phoneFitted = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(host.fitToView());
    });
  }

  Widget _buildTouch(BuildContext context) {
    final fontSize =
        ref.watch(deviceTerminalFontSizeProvider) ?? kPhoneTerminalFontSize;
    final host = _host;
    final Widget body = host == null
        ? _touchGrid(fontSize, atSessionGrid: false)
        : ValueListenableBuilder<bool>(
            valueListenable: host.atSessionGrid,
            builder: (context, atSessionGrid, _) => atSessionGrid
                // The session's grid arrives with presence.
                ? ValueListenableBuilder<HostPresence?>(
                    valueListenable: host.presence,
                    builder: (context, _, _) =>
                        _touchGrid(fontSize, atSessionGrid: true),
                  )
                : _touchGrid(fontSize, atSessionGrid: false),
          );
    return Column(
      children: [
        Expanded(
          child: Listener(
            onPointerDown: _onTouchDown,
            onPointerMove: _onTouchMove,
            onPointerUp: _onTouchUp,
            onPointerCancel: _onTouchCancel,
            child: Stack(
              fit: StackFit.expand,
              children: [
                body,
                Positioned(
                  top: Insets.xs,
                  left: Insets.xs,
                  right: Insets.xs,
                  child: _TouchSelectionBar(
                    controller: widget.instance.controller,
                    onCopy: _copySelection,
                    onPaste: _pasteFromBar,
                    onSelectAll: _selectAll,
                    onMore: widget.onSecondaryTapDown,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Under the grid, so it rides above the soft keyboard with the pane.
        TerminalKeyBar(
          terminal: widget.instance.terminal,
          focusNode: widget.instance.focusNode,
        ),
      ],
    );
  }

  Widget _touchGrid(
    double fontSize, {
    required bool atSessionGrid,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final cell = _cellSizeFor(fontSize);
      _viewWidth = constraints.maxWidth;
      if (cell.width > 0 && cell.height > 0) {
        _host?.viewGrid = (
          math.max(1, (constraints.maxWidth - _gridInset) ~/ cell.width),
          math.max(1, (constraints.maxHeight - _gridInset) ~/ cell.height),
        );
      }
      _fitToPhoneOnShow(atSessionGrid: atSessionGrid);
      // The keyboard coming up shrinks the pane; the cursor is kept in view.
      final keyboardUp = View.of(context).viewInsets.bottom > 0;
      if (keyboardUp && !_keyboardUp) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) _revealCursor();
        });
      }
      _keyboardUp = keyboardUp;
      final view = _terminalView(
        fontSize: fontSize,
        autoResize: !atSessionGrid,
        touch: true,
      );
      if (!atSessionGrid) return view;
      final columns = math.max(
        _host?.presence.value?.columns ?? 0,
        widget.instance.terminal.viewWidth,
      );
      return ValueListenableBuilder<bool>(
        valueListenable: _pinching,
        builder: (context, pinching, grid) => SingleChildScrollView(
          controller: _panController,
          scrollDirection: Axis.horizontal,
          // Two fingers are zooming, not panning.
          physics: pinching ? const NeverScrollableScrollPhysics() : null,
          child: grid,
        ),
        child: SizedBox(
          width: math.max(
            constraints.maxWidth,
            columns * cell.width + _gridInset,
          ),
          height: constraints.maxHeight,
          child: view,
        ),
      );
    },
  );

  void _revealCursor() {
    final pan = _panController;
    if (!pan.hasClients) return;
    final position = pan.position;
    final cell = _cellSizeFor(_touchFontSize).width;
    final x = Insets.sm + widget.instance.terminal.buffer.cursorX * cell;
    final left = position.pixels;
    final width = position.viewportDimension;
    if (x >= left && x + cell <= left + width) return;
    pan.jumpTo(
      (x - width / 2).clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  double _spread() {
    final points = _touches.values.take(2).toList();
    return points.length < 2 ? 0 : (points[0] - points[1]).distance;
  }

  void _onTouchDown(PointerDownEvent event) {
    ref
        .read(terminalSessionsControllerProvider.notifier)
        .focusPane(widget.instance.id);
    _touches[event.pointer] = event.position;
    _touchDowns[event.pointer] = event.position;
    if (_touches.length == 1) {
      _pressedAt = event.position;
      _pressedTime = DateTime.now();
      _selectedAtDown = widget.instance.controller.selection != null;
      _multiTouch = false;
      return;
    }
    _multiTouch = true;
    if (_touches.length != 2) return;
    _pinchSpread = _spread();
    _pinchFont = _touchFontSize;
    _twoFingerMoved = false;
    _twoFingerDownAt = DateTime.now();
    _pinching.value = true;
  }

  void _onTouchMove(PointerMoveEvent event) {
    if (!_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = event.position;
    final start = _pinchSpread;
    if (_touches.length != 2 || start == null || start <= 0) return;
    if (!_twoFingerMoved) {
      final travelled = _touches.entries.any(
        (touch) =>
            (touch.value - (_touchDowns[touch.key] ?? touch.value)).distance >
            kTouchSlop,
      );
      if (!travelled) return;
      _twoFingerMoved = true;
    }
    // Half-point steps: every frame's exact size would re-measure the font.
    final size = (_pinchFont * _spread() / start * 2).roundToDouble() / 2;
    if (size != _touchFontSize) {
      ref.read(deviceTerminalFontSizeProvider.notifier).set(size);
    }
  }

  void _onTouchUp(PointerUpEvent event) {
    final wasTwo = _touches.length == 2;
    _touches.remove(event.pointer);
    _touchDowns.remove(event.pointer);
    if (wasTwo) return _endTwoFingers();
    if (_touches.isNotEmpty) return;
    final pressedAt = _pressedAt;
    final pressedTime = _pressedTime;
    _pressedAt = null;
    _pressedTime = null;
    if (_multiTouch || _selectedAtDown) return;
    if (pressedAt == null || pressedTime == null) return;
    if ((event.position - pressedAt).distance > kTouchSlop) return;
    if (DateTime.now().difference(pressedTime) > _tapTimeout) return;
    if (widget.instance.controller.selection != null) return;
    unawaited(_tapLink(event.position));
  }

  void _onTouchCancel(PointerCancelEvent event) {
    final wasTwo = _touches.length == 2;
    _touches.remove(event.pointer);
    _touchDowns.remove(event.pointer);
    _pressedAt = null;
    if (!wasTwo) return;
    _pinchSpread = null;
    _twoFingerDownAt = null;
    _pinching.value = false;
  }

  /// The second finger lifted: a pinch ended, or it was a two-finger tap —
  /// and two of those fit the session's width.
  void _endTwoFingers() {
    _pinchSpread = null;
    _pinching.value = false;
    final downAt = _twoFingerDownAt;
    _twoFingerDownAt = null;
    if (_twoFingerMoved || downAt == null) return;
    final now = DateTime.now();
    if (now.difference(downAt) > _tapTimeout) return;
    final last = _lastTwoFingerTap;
    if (last != null && now.difference(last) < _twoFingerDoubleTap) {
      _lastTwoFingerTap = null;
      _fitWidth();
    } else {
      _lastTwoFingerTap = now;
    }
  }

  /// This device's font size at which the session's columns fill the view.
  /// Only at the session's grid: a fitted pane already fills it.
  void _fitWidth() {
    if (_host?.drawsAtSessionGrid != true) return;
    final columns = widget.instance.terminal.viewWidth;
    final available = _viewWidth - _gridInset;
    if (columns <= 0 || available <= 0) return;
    final font = _touchFontSize;
    final cell = _cellSizeFor(font).width;
    if (cell <= 0) return;
    final fitted = font * available / (columns * cell);
    ref
        .read(deviceTerminalFontSizeProvider.notifier)
        .set((fitted * 2).floorToDouble() / 2);
    if (_panController.hasClients) _panController.jumpTo(0);
  }

  /// A tap with nothing selected: a link under it is offered in a sheet,
  /// since a phone has no Ctrl+click and a stray tap must not open anything.
  Future<void> _tapLink(Offset position) async {
    final cell = _cellAt(position);
    if (cell == null) return;
    final terminal = widget.instance.terminal;
    final buffer = terminal.buffer;
    if (cell.y >= buffer.lines.length) return;
    var link = osc8LinkAt(terminal, cell.y, cell.x);
    if (link == null) {
      final line = linkLineAt(buffer, cell.y);
      link = linkAt(line, cell.y, cell.x);
      if (link == null) {
        final reference = _imageRefAt(line, cell.y, cell.x);
        if (reference == null) return;
        _closeKeyboard();
        return _openImageRef(reference.reference);
      }
    }
    final target = link.target;
    if (target is UrlTarget) {
      if (await _confirmLink('Open link', target.url) != true) return;
      return widget.linkActions.openUrl(target.url);
    }
    final path = target as PathTarget;
    final hostPath = hostPathForTerminalTarget(
      path,
      workingDirectory: widget.instance.workingDirectory,
      profileId: widget.instance.profileId,
    );
    if (hostPath == null) return;
    final kind = await _kindOf(hostPath);
    // A folder has nowhere to open on a phone; nothing there is a dead word.
    if (!mounted || kind != TerminalPathKind.file) return;
    final location = path.label.substring(path.path.length);
    if (await _confirmLink('Open in the editor', '$hostPath$location') !=
        true) {
      return;
    }
    if (!mounted) return;
    await _open(link, _Resolved(hostPath, TerminalPathKind.file));
  }

  void _closeKeyboard() => _viewKey.currentState?.closeKeyboard();

  Future<bool?> _confirmLink(String verb, String target) {
    _closeKeyboard();
    return showAdaptiveModal<bool>(
      context: context,
      title: verb,
      builder: (context) => _LinkConfirm(verb: verb, target: target),
    );
  }

  void _copySelection() {
    final controller = widget.instance.controller;
    final selection = controller.selection;
    if (selection == null) return;
    final text = terminalCopyText(widget.instance.terminal.buffer, selection);
    if (text.isNotEmpty) {
      unawaited(Clipboard.setData(ClipboardData(text: text)));
    }
    controller.clearSelection();
  }

  void _pasteFromBar() {
    widget.instance.controller.clearSelection();
    unawaited(
      pasteIntoTerminal(
        widget.instance.terminal,
        controller: widget.instance.controller,
        keyToProgram: imagePasteKeyFor(ref, widget.instance),
      ),
    );
  }

  void _selectAll() {
    final terminal = widget.instance.terminal;
    widget.instance.controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(
        terminal.viewWidth,
        terminal.buffer.height - 1,
      ),
      mode: SelectionMode.line,
    );
  }
}

/// A selection's actions at touch density, where there is no right-click:
/// Copy, Paste, Select all, and ⋯ for the pane's whole menu.
class _TouchSelectionBar extends StatelessWidget {
  const _TouchSelectionBar({
    required this.controller,
    required this.onCopy,
    required this.onPaste,
    required this.onSelectAll,
    required this.onMore,
  });

  final TerminalController controller;
  final VoidCallback onCopy;
  final VoidCallback onPaste;
  final VoidCallback onSelectAll;
  final void Function(Offset globalPosition) onMore;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.selection == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        Widget action(String label, VoidCallback onPressed) => TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(Touch.target, Touch.target),
          ),
          onPressed: onPressed,
          child: Text(label),
        );
        return Center(
          child: Material(
            elevation: 3,
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Radii.md),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  action('Copy', onCopy),
                  action('Paste', onPaste),
                  action('Select all', onSelectAll),
                  Builder(
                    builder: (context) => IconButton(
                      tooltip: 'More',
                      icon: const Icon(AppIcons.dotsThree),
                      onPressed: () {
                        final box = context.findRenderObject() as RenderBox?;
                        if (box == null) return;
                        onMore(box.localToGlobal(box.size.center(Offset.zero)));
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// What a tapped link would open, and the choice to open it.
class _LinkConfirm extends StatelessWidget {
  const _LinkConfirm({required this.verb, required this.target});

  final String verb;
  final String target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            target,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: kMonoFamily,
            ),
          ),
          const SizedBox(height: Insets.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(Touch.target, Touch.target),
                ),
                icon: const Icon(AppIcons.copy),
                label: const Text('Copy'),
                onPressed: () {
                  unawaited(Clipboard.setData(ClipboardData(text: target)));
                  Navigator.of(context).pop(false);
                },
              ),
              const SizedBox(width: Insets.sm),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(Touch.target, Touch.target),
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(verb),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

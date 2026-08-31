import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../../app/shell/shell_shortcuts.dart';
import '../../../app/theme/design_tokens.dart';
import '../data/terminal_instance.dart';
import '../domain/terminal_links.dart';
import '../domain/terminal_search.dart';

/// One pane's terminal grid, and the link affordance over it.
///
/// Split out of `TerminalPaneStack` for two reasons. It needs state of its own
/// — a `GlobalKey` onto the view, and which link the pointer is over — and
/// keying it by the instance keeps the "starting a pane swaps its instance in
/// place" rule that `ObjectKey(instance)` was already carrying: a new instance
/// is a new element, with a new focus node and no stale hover.
///
/// ## Links
///
/// The owner's report was "links are not clickable in chitragupta's terminal".
/// They are now, on **Ctrl+click** (Cmd on macOS) — VS Code's and Windows
/// Terminal's gesture, and the only safe one: a plain click in a terminal
/// places a selection and, when the program has asked for mouse reporting, is
/// an event the program itself receives. Opening a browser on it would be a
/// side effect of clicking anywhere.
///
/// Discoverability is the hover: the URL under the pointer is highlighted and
/// the pane says `Ctrl+click to open …` along its bottom edge, so the gesture
/// is visible before it is needed rather than being something you had to
/// already know.
///
/// ## What this costs at 100 panes
///
/// Nothing, for 99 of them. Detection is driven by [MouseRegion.onHover], so a
/// pane with no pointer over it never runs it — there is no per-write, per-line
/// or per-frame scan, and the output path is untouched. The hovered pane pays
/// one [lineTextOf] plus one regex over that single line, and only when the
/// pointer crosses into a different cell.
///
/// The highlight itself is xterm's own [TerminalController.highlight], the same
/// mechanism find-in-scrollback uses: it is anchored to the buffer, so it stays
/// on its text as output scrolls, and there is at most one of them.
///
/// ## OSC 8 is not honoured yet
///
/// The vendored fork drops `OSC 8` hyperlinks at `unknownOSC` — the escape is
/// consumed, so the label still renders, but no link is recorded. Honouring it
/// means carrying a hyperlink id on every cell, which changes `BufferLine`'s
/// packed stride and everything that walks it (reflow, snapshot, the batched
/// painter and its pixel goldens). Out of proportion to the gain here: an agent
/// that emits `OSC 8` almost always uses the URL itself as the label, and that
/// is detected by the text scan below. Recorded in `docs/loop-reports/loop-84.md`.
class TerminalPaneView extends StatefulWidget {
  const TerminalPaneView({
    required this.instance,
    required this.focused,
    required this.fontSize,
    required this.terminalTheme,
    required this.chordOverrides,
    required this.onKeyEvent,
    required this.onSecondaryTapDown,
    required this.openUrl,
    super.key,
  });

  final TerminalInstance instance;
  final bool focused;
  final double fontSize;
  final TerminalTheme terminalTheme;
  final Map<String, bool> chordOverrides;
  final FocusOnKeyEventCallback onKeyEvent;
  final void Function(Offset globalPosition) onSecondaryTapDown;

  /// Opens a URL outside the app. Injected, so a test records what a click
  /// would have opened instead of launching a browser at the machine.
  final Future<bool> Function(String url) openUrl;

  @override
  State<TerminalPaneView> createState() => _TerminalPaneViewState();
}

/// How far the pointer may move between press and release and still be a click
/// rather than the start of a selection drag.
const double _clickSlop = 4;

class _TerminalPaneViewState extends State<TerminalPaneView> {
  /// Reaches `TerminalViewState.renderTerminal`, which is the only thing that
  /// can turn a pointer position into a buffer cell — it owns the cell metrics
  /// and the scroll offset.
  final _viewKey = GlobalKey<TerminalViewState>();

  TerminalLink? _link;
  int? _linkRow;
  CellOffset? _lastCell;
  TerminalHighlight? _highlight;

  @override
  void dispose() {
    _highlight?.dispose();
    super.dispose();
  }

  /// The buffer cell under a **screen** position.
  ///
  /// Screen, not local: `TerminalView` hands its tap callbacks a `CellOffset`
  /// derived from `TapUpDetails.localPosition`, which is local to the gesture
  /// detector — a widget that sits *outside* the padded `Container` the grid is
  /// drawn in, while `getCellOffset` only subtracts the `MediaQuery` padding.
  /// The two disagree by the pane's own padding, so a tap and a hover would
  /// land on different cells. Going through `globalToLocal` gives the render
  /// object's own coordinates and makes both paths agree.
  CellOffset? _cellAt(Offset globalPosition) {
    final state = _viewKey.currentState;
    if (state == null) return null;
    try {
      final render = state.renderTerminal;
      return render.getCellOffset(render.globalToLocal(globalPosition));
    } catch (_) {
      // The viewport is between builds; there is nothing under the pointer to
      // report yet, and the next move will ask again.
      return null;
    }
  }

  void _onHover(PointerHoverEvent event) {
    final cell = _cellAt(event.position);
    if (cell == null || cell == _lastCell) return;
    _lastCell = cell;

    final lines = widget.instance.terminal.buffer.lines;
    if (cell.y >= lines.length) return _setLink(null, null);
    final link = linkAt(lineTextOf(lines[cell.y]), cell.x);
    if (link == _link && cell.y == _linkRow) return;
    _setLink(link, cell.y);
  }

  void _setLink(TerminalLink? link, int? row) {
    _highlight?.dispose();
    _highlight = null;
    if (link != null && row != null) {
      final buffer = widget.instance.terminal.buffer;
      _highlight = widget.instance.controller.highlight(
        p1: buffer.createAnchor(link.startColumn, row),
        p2: buffer.createAnchor(link.endColumn, row),
        // Translucent, like a search hit: the URL has to stay readable under
        // its own affordance.
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
      );
    }
    if (link == _link && row == _linkRow) return;
    setState(() {
      _link = link;
      _linkRow = row;
    });
  }

  void _onExit(PointerExitEvent event) {
    _lastCell = null;
    _setLink(null, null);
  }

  /// Where the primary button went down, so a drag is not read as a click.
  Offset? _pressedAt;

  void _onPointerDown(PointerDownEvent event) {
    _pressedAt = event.buttons == kPrimaryButton ? event.position : null;
  }

  void _onPointerUp(PointerUpEvent event) {
    final pressedAt = _pressedAt;
    _pressedAt = null;
    final link = _link;
    if (pressedAt == null || link == null) return;
    // A drag that ended over a link is a selection, not a click on it.
    if ((event.position - pressedAt).distance > _clickSlop) return;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed && !keyboard.isMetaPressed) return;
    final cell = _cellAt(event.position);
    if (cell == null || cell.y != _linkRow || !link.contains(cell.x)) return;
    widget.openUrl(link.url);
  }

  @override
  Widget build(BuildContext context) {
    final view = TerminalView(
      widget.instance.terminal,
      key: _viewKey,
      controller: widget.instance.controller,
      focusNode: widget.instance.focusNode,
      scrollController: widget.instance.scrollController,
      theme: widget.terminalTheme,
      textStyle: TerminalStyle(
        fontSize: widget.fontSize,
        fontFamily: kMonoFamily,
      ),
      // The grid's size is its own setting; the app-wide UI text scale must
      // not compound onto it.
      textScaler: TextScaler.noScaling,
      padding: const EdgeInsets.all(Insets.sm),
      autofocus: widget.focused,
      // Desktop uses the physical keyboard; this also avoids xterm opening a
      // software text-input client, which on Windows fails with "Could not set
      // client, view ID is null" and blanks the terminal.
      hardwareKeyboardOnly: true,
      onKeyEvent: widget.onKeyEvent,
      // xterm's own shortcut manager runs after `onKeyEvent` and before
      // `Terminal.keyInput`; its Windows defaults quietly took Ctrl+A and
      // Ctrl+V from the shell. Ctrl+V is paste again, but declared — and so
      // switchable in Settings, which is what the overrides are doing here.
      shortcuts: terminalPaneShortcutsFor(widget.chordOverrides),
      // Over a link the pointer says so; everywhere else the grid is text.
      mouseCursor: _link == null
          ? SystemMouseCursors.text
          : SystemMouseCursors.click,
      // Right-click → copy selection / paste / end the session.
      onSecondaryTapDown: (details, _) =>
          widget.onSecondaryTapDown(details.globalPosition),
    );

    return MouseRegion(
      // No cursor of its own: `TerminalView`'s own `MouseRegion` is nearer the
      // pointer and wins, so the cursor is set through `mouseCursor` above.
      onHover: _onHover,
      onExit: _onExit,
      child: Listener(
        // Raw pointer events rather than `TerminalView.onTapUp`, for two
        // reasons. The package never calls that callback — its gesture
        // detector only ever invokes `onSingleTapUp`, which `TerminalView`
        // does not pass on, so the parameter is dead upstream. And a modified
        // click must not enter the gesture arena at all: the pane's own tap
        // recognisers own selection, and competing with them for the same tap
        // is how you get a link that opens only sometimes.
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        child: Stack(
          fit: StackFit.expand,
          children: [view, if (_link != null) _LinkHint(url: _link!.url)],
        ),
      ),
    );
  }
}

/// The browser-style hint along the bottom of a pane with a link under the
/// pointer. Says the gesture, because Ctrl+click is not guessable.
class _LinkHint extends StatelessWidget {
  const _LinkHint({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Positioned(
      left: 0,
      bottom: 0,
      right: 0,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Container(
            margin: const EdgeInsets.all(Insets.xs),
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              // Ctrl on Windows and Linux, Cmd on macOS — both are accepted,
              // and the one named is the one the platform's users expect.
              '${_modifierLabel()}+click to open  $url',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _modifierLabel() =>
      defaultTargetPlatform == TargetPlatform.macOS ? 'Cmd' : 'Ctrl';
}

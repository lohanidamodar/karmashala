import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../../app/shell/shell_shortcuts.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../media/application/session_media_providers.dart';
import '../../media/domain/session_image_reference.dart';
import '../../media/presentation/session_image_dialog.dart';
import '../application/terminal_link_actions.dart';
import '../application/terminal_paste.dart';
import '../application/terminal_sessions_controller.dart';
import '../data/terminal_instance.dart';
import 'package:karmashala_terminal_core/grid.dart';

/// One pane's terminal grid, plus the Ctrl+click (Cmd on macOS) affordance over
/// URLs, paths, `path:12:7` and `[Image #6]`. Nothing is detected until the
/// modifier is down; a plain click stays a selection.
class TerminalPaneView extends ConsumerStatefulWidget {
  const TerminalPaneView({
    required this.instance,
    required this.focused,
    required this.fontSize,
    required this.terminalTheme,
    required this.chordOverrides,
    required this.onKeyEvent,
    required this.onSecondaryTapDown,
    required this.linkActions,
    super.key,
  });

  final TerminalInstance instance;
  final bool focused;
  final double fontSize;
  final TerminalTheme terminalTheme;
  final Map<String, bool> chordOverrides;
  final FocusOnKeyEventCallback onKeyEvent;
  final void Function(Offset globalPosition) onSecondaryTapDown;

  /// Injected, so a test records what a Ctrl+click would have done instead of
  /// starting a browser or an editor on the machine running it.
  final TerminalLinkActions linkActions;

  @override
  ConsumerState<TerminalPaneView> createState() => _TerminalPaneViewState();
}

/// How far the pointer may move between press and release and still be a click
/// rather than the start of a selection drag.
const double _clickSlop = 4;

/// A `[Image #6]` in buffer rows and cell columns: `BufferLine.getText()` skips
/// empty cells and double-width tails, so an underline computed from character
/// indices lands beside its text.
class _ImageRefSpan {
  const _ImageRefSpan({
    required this.reference,
    required this.startRow,
    required this.startColumn,
    required this.endRow,
    required this.endColumn,
  });

  final SessionImageReference reference;
  final int startRow;
  final int startColumn;
  final int endRow;
  final int endColumn;

  bool contains(int row, int column) {
    if (row < startRow || row > endRow) return false;
    if (row == startRow && column < startColumn) return false;
    if (row == endRow && column >= endColumn) return false;
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is _ImageRefSpan &&
      other.reference == reference &&
      other.startRow == startRow &&
      other.startColumn == startColumn &&
      other.endRow == endRow &&
      other.endColumn == endColumn;

  @override
  int get hashCode =>
      Object.hash(reference, startRow, startColumn, endRow, endColumn);
}

/// A path candidate that turned out to be something.
class _Resolved {
  const _Resolved(this.hostPath, this.kind);

  final String hostPath;
  final TerminalPathKind kind;
}

/// How many probe answers a pane remembers while the pointer is inside it.
/// Dropped on exit, so a file created after a miss is found on the next visit.
const int _maxProbeCache = 64;

class _TerminalPaneViewState extends ConsumerState<TerminalPaneView> {
  /// Reaches `TerminalViewState.renderTerminal`, the only thing that can turn a
  /// pointer position into a buffer cell.
  final _viewKey = GlobalKey<TerminalViewState>();

  TerminalLink? _link;
  _Resolved? _resolved;

  /// The `[Image #6]` under the pointer. Kept beside [_link], not folded in: a
  /// path underlines only once the filesystem confirms it, a reference on sight.
  _ImageRefSpan? _imageRef;

  CellOffset? _lastCell;
  TerminalUnderline? _highlight;

  /// Whether the link modifier is down. Detection does nothing until it is.
  bool _modifier = false;

  /// Where the pointer last was, so pressing Ctrl without moving the mouse
  /// still lights up what is under it.
  Offset? _pointer;

  /// Registered on pointer enter and dropped on exit, so exactly one pane ever
  /// listens no matter how many are open.
  bool _listening = false;

  /// Answers from [TerminalLinkActions.kindOf], so sliding along one path does
  /// not `stat` it once per cell.
  final Map<String, TerminalPathKind?> _probed = {};

  /// Discards the answer to a probe that is no longer the one being asked for.
  int _epoch = 0;

  /// The session this pane belongs to, or null for a plain shell — media is
  /// per-session, so a plain tab can never resolve a `[Image #6]`.
  String? get _sessionId => widget.instance.agentLaunch?.sessionId;

  @override
  void dispose() {
    _stopListening();
    _highlight?.dispose();
    super.dispose();
  }

  void _startListening() {
    if (_listening) return;
    _listening = true;
    HardwareKeyboard.instance.addHandler(_onKeyboardChanged);
  }

  void _stopListening() {
    if (!_listening) return;
    _listening = false;
    HardwareKeyboard.instance.removeHandler(_onKeyboardChanged);
  }

  /// Watches the modifier so the underline appears the moment Ctrl goes down,
  /// not on the next mouse move. Never handles the event.
  bool _onKeyboardChanged(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final down = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (down == _modifier) return false;
    _modifier = down;
    if (down) {
      _resolveAt(_pointer);
    } else {
      _forget();
    }
    return false;
  }

  /// The buffer cell under a **screen** position. Via `globalToLocal`, because
  /// `getCellOffset` subtracts only the MediaQuery padding: a local position
  /// from the gesture detector outside the padded grid lands on another cell.
  CellOffset? _cellAt(Offset globalPosition) {
    final state = _viewKey.currentState;
    if (state == null) return null;
    try {
      final render = state.renderTerminal;
      return render.getCellOffset(render.globalToLocal(globalPosition));
    } catch (_) {
      // The viewport is between builds; the next move will ask again.
      return null;
    }
  }

  void _onEnter(PointerEnterEvent event) {
    _pointer = event.position;
    _startListening();
    final keyboard = HardwareKeyboard.instance;
    _modifier = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (_modifier) _resolveAt(event.position);
  }

  /// The whole per-move cost with Ctrl up: one field write.
  void _onHover(PointerHoverEvent event) {
    _pointer = event.position;
    if (!_modifier) return;
    _resolveAt(event.position);
  }

  void _onExit(PointerExitEvent event) {
    _stopListening();
    _pointer = null;
    _modifier = false;
    _probed.clear();
    _forget();
  }

  /// Works out what is under [position] and lights it up, or clears. The `stat`
  /// at the end is the only filesystem call; detection above it is pure text.
  Future<void> _resolveAt(Offset? position) async {
    if (position == null) return;
    final cell = _cellAt(position);
    if (cell == null) return _forget();
    // The same cell has the same answer, and we already gave it.
    if (cell == _lastCell) return;
    _lastCell = cell;

    final terminal = widget.instance.terminal;
    final buffer = terminal.buffer;
    if (cell.y >= buffer.lines.length) return _clearLink();
    // A program that said "this is a link" outranks a guess about the text,
    // and the attribute read is cheaper than the scan below.
    final hyperlink = osc8LinkAt(terminal, cell.y, cell.x);
    if (hyperlink != null) {
      if (hyperlink == _link) return;
      return _showHyperlink(hyperlink);
    }
    final line = linkLineAt(buffer, cell.y);
    final link = linkAt(line, cell.y, cell.x);
    if (link == null) {
      // Not a path or a URL — but it may be an `[Image #6]`. Looked for only
      // here, so a cell that already resolved to a path costs nothing new.
      final reference = _imageRefAt(line, cell.y, cell.x);
      if (reference == null) return _clearLink();
      // Still the same reference, one cell along: already underlined.
      if (reference == _imageRef) return;
      return _showImageRef(reference);
    }
    // Still the same link, one cell along: it is already underlined.
    if (link == _link) return;

    final target = link.target;
    if (target is UrlTarget) return _show(link, null);

    final hostPath = hostPathForTerminalTarget(
      target as PathTarget,
      workingDirectory: widget.instance.workingDirectory,
      profileId: widget.instance.profileId,
    );
    if (hostPath == null) return _clearLink();

    final epoch = ++_epoch;
    final kind = await _kindOf(hostPath);
    // The pointer moved, or Ctrl came up, while we were asking.
    if (!mounted || epoch != _epoch) return;
    // Nothing there — opening the wrong thing is worse than a dead word.
    if (kind == null) return _clearLink();
    _show(link, _Resolved(hostPath, kind));
  }

  /// The `[Image #6]` covering cell ([row], [column]) of [line], or null — and
  /// always null in a pane with no session, which could never resolve one.
  _ImageRefSpan? _imageRefAt(TerminalLinkLine line, int row, int column) {
    if (_sessionId == null) return null;
    for (final reference in imageReferencesIn(line.text)) {
      // Character indices back onto cells: `getText()` skips empty cells and
      // double-width tails, so the underline would otherwise land beside them.
      final last = reference.end - 1;
      final span = _ImageRefSpan(
        reference: reference,
        startRow: line.rowOfChar[reference.start],
        startColumn: line.cellOfChar[reference.start],
        endRow: line.rowOfChar[last],
        endColumn: line.cellOfChar[last] + line.widthOfChar[last],
      );
      if (span.contains(row, column)) return span;
    }
    return null;
  }

  /// Underlines a reference. No probe first: unlike a path candidate this is
  /// not a guess about what a word might be — the CLI wrote it.
  void _showImageRef(_ImageRefSpan span) {
    _highlightSpan(
      span.startRow,
      span.startColumn,
      span.endRow,
      span.endColumn,
    );
    setState(() {
      _link = null;
      _resolved = null;
      _imageRef = span;
    });
  }

  /// Opens the picture a reference names, or says why it cannot. The lookup
  /// reads the transcript, so it runs on a click and never on the hover path.
  Future<void> _openImageRef(SessionImageReference reference) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final found = await ref.read(sessionImageLookupProvider)(
      sessionId,
      reference.pasteId,
    );
    if (!mounted) return;
    switch (found) {
      case SessionImageFound(
        :final item,
        :final matches,
        :final resolveHostPath,
      ):
        await showDialog<void>(
          context: context,
          builder: (_) => SessionImageDialog(
            reference: reference.label,
            item: item,
            matches: matches,
            resolveHostPath: resolveHostPath,
            now: ref.read(clockProvider).nowUtc(),
          ),
        );
      case SessionImageUnavailable(:final reason):
        // In words: a silent click is indistinguishable from a broken link.
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(reason)));
    }
  }

  Future<TerminalPathKind?> _kindOf(String hostPath) async {
    if (_probed.containsKey(hostPath)) return _probed[hostPath];
    final kind = await widget.linkActions.kindOf(hostPath);
    if (_probed.length >= _maxProbeCache) _probed.clear();
    _probed[hostPath] = kind;
    return kind;
  }

  /// Underlines [link], across every row it covers.
  void _show(TerminalLink link, _Resolved? resolved) {
    _highlightSpan(
      link.startRow,
      link.startColumn,
      link.endRow,
      link.endColumn,
    );
    setState(() {
      _link = link;
      _resolved = resolved;
      _imageRef = null;
    });
  }

  /// Offers an `OSC 8` hyperlink without drawing a rule under it: the cells
  /// carry the id, so xterm2's own painter already underlines them.
  void _showHyperlink(TerminalLink link) {
    _dropUnderline();
    setState(() {
      _link = link;
      _resolved = null;
      _imageRef = null;
    });
  }

  /// The underline itself, shared by both kinds of target.
  void _highlightSpan(
    int startRow,
    int startColumn,
    int endRow,
    int endColumn,
  ) {
    _dropUnderline();
    final buffer = widget.instance.terminal.buffer;
    // A rule under the text, not a wash over it — the link stays readable.
    _highlight = widget.instance.controller.underline(
      p1: buffer.createAnchor(startColumn, startRow),
      p2: buffer.createAnchor(endColumn, endRow),
      color: Theme.of(context).colorScheme.primary,
    );
  }

  void _dropUnderline() {
    _highlight?.dispose();
    _highlight = null;
  }

  /// Drops the underline, keeping the "this cell has been answered" memory.
  void _clearLink() {
    _dropUnderline();
    if (_link == null && _imageRef == null) return;
    setState(() {
      _link = null;
      _resolved = null;
      _imageRef = null;
    });
  }

  /// Drops the underline *and* the memory, so the same cell is asked about
  /// again — what releasing and re-pressing Ctrl has to mean.
  void _forget() {
    _epoch++;
    _lastCell = null;
    _clearLink();
  }

  /// `Ctrl+C` copies when there is a selection and interrupts when there is
  /// not; the answer depends on this pane right now, so it cannot live in the
  /// static chord map. Returns null when this is not that chord.
  KeyEventResult? _handleCopyOrInterrupt(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.keyC) return null;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed ||
        keyboard.isShiftPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return null;
    }
    final controller = widget.instance.controller;
    final selection = controller.selection;
    // No selection: ^C, byte for byte as before.
    if (selection == null) return null;
    if (event is KeyDownEvent) {
      final text = widget.instance.terminal.buffer.getText(selection);
      if (text.isNotEmpty) Clipboard.setData(ClipboardData(text: text));
      controller.clearSelection();
    }
    // The key-up and any repeat are swallowed too, or xterm's fallback would
    // type the control character for a chord already answered.
    return KeyEventResult.handled;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) =>
      _handleCopyOrInterrupt(event) ?? widget.onKeyEvent(node, event);

  /// Where the primary button went down, so a drag is not read as a click.
  Offset? _pressedAt;

  void _onPointerDown(PointerDownEvent event) {
    _pressedAt = event.buttons == kPrimaryButton ? event.position : null;
    ref
        .read(terminalSessionsControllerProvider.notifier)
        .focusPane(widget.instance.id);
  }

  void _onPointerUp(PointerUpEvent event) {
    final pressedAt = _pressedAt;
    _pressedAt = null;
    final link = _link;
    final reference = _imageRef;
    if (pressedAt == null || (link == null && reference == null)) return;
    // A drag that ended over a link is a selection, not a click on it.
    if ((event.position - pressedAt).distance > _clickSlop) return;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed && !keyboard.isMetaPressed) return;
    final cell = _cellAt(event.position);
    if (cell == null) return;
    if (reference != null) {
      if (reference.contains(cell.y, cell.x)) {
        _openImageRef(reference.reference);
      }
      return;
    }
    if (!link!.contains(cell.y, cell.x)) return;
    _open(link);
  }

  Future<void> _open(TerminalLink link) async {
    final target = link.target;
    if (target is UrlTarget) return widget.linkActions.openUrl(target.url);
    final resolved = _resolved;
    if (resolved == null) return;
    final error = await widget.linkActions.open(
      resolved.hostPath,
      resolved.kind,
      line: (target as PathTarget).line,
      column: target.column,
    );
    if (error == null || !mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(error)));
  }

  /// What the hint says the click will do, or null. The *resolved* path, not
  /// the printed one; a reference names itself, having nothing to resolve yet.
  (String, String)? get _hint {
    final reference = _imageRef;
    if (reference != null) return ('preview', reference.reference.label);
    final link = _link;
    return link == null ? null : _hintFor(link);
  }

  (String, String) _hintFor(TerminalLink link) {
    final resolved = _resolved;
    if (resolved == null) return ('open', link.target.label);
    final location = link.target is PathTarget
        ? (link.target as PathTarget).label.substring(
            (link.target as PathTarget).path.length,
          )
        : '';
    return (
      resolved.kind == TerminalPathKind.directory ? 'reveal' : 'open',
      '${resolved.hostPath}$location',
    );
  }

  @override
  Widget build(BuildContext context) {
    final view = Actions(
      // The app's own paste, above xterm's text-only one: `TerminalPasteIntent`
      // is a type xterm has no entry for, so an ancestor gets the chord.
      actions: {
        TerminalPasteIntent: CallbackAction<TerminalPasteIntent>(
          onInvoke: (_) => pasteIntoTerminal(
            widget.instance.terminal,
            controller: widget.instance.controller,
          ),
        ),
      },
      child: TerminalView(
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
        // `true` swaps in `CustomKeyboardListener`, which never calls
        // `TextInput.attach` — dictation and IMEs then silently cannot type into a
        // pane. It was `true` to dodge a "view ID is null" bug xterm2 has fixed.
        hardwareKeyboardOnly: false,
        onKeyEvent: _onKeyEvent,
        // xterm's Windows defaults quietly took Ctrl+A and Ctrl+V from the shell;
        // the overrides declare them so Settings can switch them back.
        shortcuts: terminalPaneShortcutsFor(widget.chordOverrides),
        // Over a link the pointer says so; everywhere else the grid is text.
        mouseCursor: _link == null && _imageRef == null
            ? SystemMouseCursors.text
            : SystemMouseCursors.click,
        // Right-click → copy selection / paste / end the session.
        onSecondaryTapDown: (details, _) =>
            widget.onSecondaryTapDown(details.globalPosition),
      ),
    );

    final hint = _hint;
    return MouseRegion(
      // No cursor of its own: `TerminalView`'s own `MouseRegion` is nearer the
      // pointer and wins, so the cursor is set through `mouseCursor` above.
      onEnter: _onEnter,
      onHover: _onHover,
      onExit: _onExit,
      child: Listener(
        // `TerminalView.onTapUp` is dead upstream — the package never calls it
        // — and a modified click must stay out of the gesture arena, or it
        // competes with the pane's own selection recognisers.
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        child: Stack(
          fit: StackFit.expand,
          children: [
            view,
            if (hint != null) _LinkHint(verb: hint.$1, target: hint.$2),
          ],
        ),
      ),
    );
  }
}

/// The browser-style hint along the bottom of a pane with a link under the
/// pointer. Names the gesture and the *resolved* target.
class _LinkHint extends StatelessWidget {
  const _LinkHint({required this.verb, required this.target});

  /// `open` or `reveal`, so a folder does not promise to open a file.
  final String verb;
  final String target;

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
              // Both are accepted; name the one the platform's users expect.
              '${_modifierLabel()}+click to $verb  $target',
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

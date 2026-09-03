import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../../app/shell/shell_shortcuts.dart';
import '../../../core/util/clock_provider.dart';
import '../../../app/theme/design_tokens.dart';
import '../../media/application/session_media_providers.dart';
import '../../media/domain/session_image_reference.dart';
import '../../media/presentation/session_image_dialog.dart';
import '../application/terminal_link_actions.dart';
import '../application/terminal_paste.dart';
import '../data/terminal_instance.dart';
import '../domain/terminal_link_resolution.dart';
import '../domain/terminal_links.dart';

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
/// The owner's report was "links are not clickable in karmashala's terminal",
/// then "any link — file link, relative file link, http link". They are, on
/// **Ctrl+click** (Cmd on macOS) — VS Code's and Windows Terminal's gesture,
/// and the only safe one: a plain click in a terminal places a selection and,
/// when the program has asked for mouse reporting, is an event the program
/// itself receives. Opening something as a side effect of clicking anywhere
/// would be wrong.
///
/// **Ctrl is the switch, not just the click.** Nothing is detected until the
/// modifier is held. Hold it and the link under the pointer underlines itself
/// and the cursor turns into a hand — every terminal's affordance, and the
/// thing that says "this is clickable" before you commit to it. Release it, or
/// move off, and the underline goes. With Ctrl up the pane behaves exactly as
/// it did before any of this existed, selection drag included.
///
/// Four kinds of target, one code path:
///
/// * an http(s) URL, opened in the browser;
/// * a directory, revealed in the host's file manager;
/// * a file, opened in the configured code editor;
/// * `path:12` / `path:12:7`, which resolves as the file and carries the
///   location for an opener that can use it (none can yet).
///
/// A path that does not exist underlines nothing and does nothing: the pane
/// asks what is at the resolved path once, for the one candidate under the
/// pointer, and stays silent when the answer is "nothing".
///
/// ## `[Image #6]`
///
/// A fifth kind, on the same gesture. The owner's report: *"image link inside
/// terminal still not wired, i should be able to ctrl click on the image
/// `[Image #6]` and preview the image in dialog"*. When a picture is pasted
/// into an agent CLI running in a pane, the CLI prints that reference as plain
/// text — there is no `OSC 8` around it — so recognising it is a text scan like
/// every other target here, and it opens [SessionImageDialog].
///
/// Two rules it does not share with a path:
///
/// * **Only a pane with a session offers one.** Media is per-session; a plain
///   shell tab has nothing to resolve a number against and must not pretend the
///   text is clickable.
/// * **It underlines without resolving first, and refuses in words.** A path
///   that is not there underlines nothing, because a path-shaped *word* is not
///   evidence of anything. `[Image #6]` is evidence: the CLI wrote it. So it is
///   offered on sight — hovering costs no transcript read at all — and if the
///   number names a picture the session does not have, the click says so in a
///   sentence. Opening nothing would look broken, and opening the nearest
///   picture instead would be worse than either.
///
/// ## What this costs at 100 panes
///
/// Nothing, in every pane, until Ctrl goes down. With the modifier up
/// [_onHover] stores the pointer position and returns — no cell lookup, no line
/// flattening, no regex, no `stat`. There is no per-write, per-line or
/// per-frame work anywhere here and the output path is untouched; the keyboard
/// handler that watches for Ctrl is registered only while the pointer is inside
/// a pane, so at most one exists no matter how many panes are open.
///
/// With Ctrl held, the hovered pane pays — only when the pointer crosses into a
/// different cell — one flatten of the hovered row (plus its wrapped
/// continuation rows, at most [kMaxWrappedRows] either side), two regex passes
/// over that text, and at most one `FileSystemEntity.type` per distinct
/// candidate, memoised until the pointer leaves the pane. The `[Image #6]` scan
/// adds a third pass over the *same* flattened text, and only on the cells the
/// first two found nothing on — so a line of paths costs exactly what it did
/// before — behind a `contains('[Image #')` that rejects an ordinary line
/// without running a regex at all. Reading the transcript is a *click's* cost;
/// no hover ever pays it.
///
/// The underline itself is xterm's own [TerminalController.underline]: it is
/// anchored to the buffer, so it stays on its text as output scrolls, and there
/// is at most one of them.
///
/// ## OSC 8 is not honoured yet
///
/// xterm2 does record `OSC 8` hyperlinks — the parser calls `setHyperlink` and
/// the painter takes an `activeHyperlinkId` — but nothing here reads them yet,
/// so a hyperlinked label is still found only by the text scan below. That is a
/// gap to close rather than a limitation of the dependency; it costs nothing in
/// practice today, because an agent that emits `OSC 8` almost always uses the
/// URL itself as the label.
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

  /// Reaches the browser, the file manager, the editor and the filesystem.
  /// Injected, so a test records what a Ctrl+click would have done instead of
  /// starting any of them on the machine running it.
  final TerminalLinkActions linkActions;

  /// A `ConsumerStatefulWidget` rather than one more injected callback: the
  /// image lookup is the pane's own business and reaching it through `ref`
  /// leaves `TerminalPaneStack`'s call site — and every other caller — exactly
  /// as it was.
  @override
  ConsumerState<TerminalPaneView> createState() => _TerminalPaneViewState();
}

/// How far the pointer may move between press and release and still be a click
/// rather than the start of a selection drag.
const double _clickSlop = 4;

/// A `[Image #6]` and where it sits on the buffer.
///
/// In **buffer rows and cell columns**, for the same reason [TerminalLink] is:
/// `BufferLine.getText()` skips empty cells and the trailing half of a
/// double-width glyph, so character indices and cells do not agree and an
/// underline computed from the former lands beside its text.
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
  /// Reaches `TerminalViewState.renderTerminal`, which is the only thing that
  /// can turn a pointer position into a buffer cell — it owns the cell metrics
  /// and the scroll offset.
  final _viewKey = GlobalKey<TerminalViewState>();

  TerminalLink? _link;
  _Resolved? _resolved;

  /// The `[Image #6]` under the pointer, when that is what is under it. Kept
  /// beside [_link] rather than folded into it because `TerminalTarget` is a
  /// sealed type in `terminal_links.dart` and a fifth case cannot be added
  /// from here — and because the two resolve on opposite terms: a path
  /// underlines only once the filesystem has confirmed it, a reference
  /// underlines on sight.
  _ImageRefSpan? _imageRef;

  CellOffset? _lastCell;
  TerminalUnderline? _highlight;

  /// Whether the link modifier is down. Detection does nothing until it is.
  bool _modifier = false;

  /// Where the pointer last was, so pressing Ctrl without moving the mouse
  /// still lights up what is under it.
  Offset? _pointer;

  /// Whether the keyboard handler is registered. It is added when the pointer
  /// enters this pane and removed when it leaves, so exactly one pane is ever
  /// listening — the cost does not grow with the number of open panes.
  bool _listening = false;

  /// Answers from [TerminalLinkActions.kindOf], so sliding along one path does
  /// not `stat` it once per cell.
  final Map<String, TerminalPathKind?> _probed = {};

  /// Discards the answer to a probe that is no longer the one being asked for.
  int _epoch = 0;

  /// The session this pane belongs to, or null for a plain shell. Media is
  /// per-session, so this is what decides whether a `[Image #6]` printed here
  /// is resolvable at all.
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
  /// rather than on the next mouse movement. Never handles anything: it only
  /// reads the keyboard's state, which is already updated by the time handlers
  /// run.
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

  /// Works out what is under [position] and lights it up, or clears.
  ///
  /// Only ever reached with the modifier held. The `stat` at the end is the one
  /// filesystem call on this path: detection above it is pure text, so a line
  /// full of path-shaped words costs regex, not I/O.
  Future<void> _resolveAt(Offset? position) async {
    if (position == null) return;
    final cell = _cellAt(position);
    if (cell == null) return _forget();
    // The same cell has the same answer, and we already gave it.
    if (cell == _lastCell) return;
    _lastCell = cell;

    final buffer = widget.instance.terminal.buffer;
    if (cell.y >= buffer.lines.length) return _clearLink();
    final line = linkLineAt(buffer, cell.y);
    final link = linkAt(line, cell.y, cell.x);
    if (link == null) {
      // Not a path and not a URL — but it may be the `[Image #6]` an agent CLI
      // printed, which is the owner's request. Looked for only here, so a cell
      // that already resolved to a path costs nothing new.
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
    // Nothing is there. Nothing visible happens — a wrong thing opened is far
    // worse than a word that turns out not to be a link.
    if (kind == null) return _clearLink();
    _show(link, _Resolved(hostPath, kind));
  }

  /// The `[Image #6]` covering cell ([row], [column]) of [line], or null.
  ///
  /// Returns null outright for a pane with no session: a reference it could
  /// never resolve must not underline, and checking first also means the scan
  /// never runs in a plain shell tab.
  _ImageRefSpan? _imageRefAt(TerminalLinkLine line, int row, int column) {
    if (_sessionId == null) return null;
    for (final reference in imageReferencesIn(line.text)) {
      // Character indices back onto buffer cells, the same mapping `linksIn`
      // makes: `getText()` skips empty cells and double-width tails, so the two
      // do not agree and the underline would land beside the text.
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

  /// Opens the picture a reference names, or says why it cannot.
  ///
  /// The lookup reads the session's transcript, so it happens here — on a
  /// deliberate click — and never on the hover path.
  Future<void> _openImageRef(SessionImageReference reference) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final found = await ref.read(sessionImageLookupProvider)(
      sessionId,
      reference.pasteId,
    );
    if (!mounted) return;
    switch (found) {
      case SessionImageFound(:final item, :final matches, :final resolveHostPath):
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
        // In words. A click that did nothing would be indistinguishable from a
        // broken link, and the nearest picture would be the wrong one.
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

  /// The underline itself, shared by both kinds of target.
  void _highlightSpan(int startRow, int startColumn, int endRow, int endColumn) {
    _highlight?.dispose();
    final buffer = widget.instance.terminal.buffer;
    // A rule under the text, not a wash over it: the link has to stay as
    // readable as the output around it. `underline` is xterm2's own API for
    // exactly that; the vendored fork got there by bolting a flag onto
    // `highlight`.
    _highlight = widget.instance.controller.underline(
      p1: buffer.createAnchor(startColumn, startRow),
      p2: buffer.createAnchor(endColumn, endRow),
      color: Theme.of(context).colorScheme.primary,
    );
  }

  /// Drops the underline, keeping the "this cell has been answered" memory.
  void _clearLink() {
    _highlight?.dispose();
    _highlight = null;
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

  /// `Ctrl+C` copies when there is a selection, and interrupts when there is
  /// not — Windows Terminal's and VS Code's rule, and the one every user who
  /// has ever pressed it in a terminal already has.
  ///
  /// This cannot live in the static chord map beside `Ctrl+V`, because the
  /// answer is not a setting: it depends on whether a selection exists *right
  /// now*, in *this* pane. So it is the pane's own key path, ahead of
  /// `onPaneKey`.
  ///
  /// Copying clears the selection, which is what makes the pair usable: the
  /// second `Ctrl+C` — the one you press because the first did not stop the
  /// program — interrupts. With no selection nothing here runs at all, so the
  /// bytes a pane sends are unchanged from before.
  ///
  /// Returns null when this is not that chord, meaning "not mine".
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

  /// What the hint says the click will do, and to what, or null when there is
  /// nothing under the pointer.
  ///
  /// The *resolved* path, not the printed one: `Ctrl+click to open
  /// C:\src\app\lib\main.dart` is the useful sentence when the output said
  /// `lib/main.dart`. A reference has nothing to resolve until it is clicked,
  /// so it names itself — which is also what tells the user the app read the
  /// number the same way they did.
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
      // The app's own paste, above `TerminalView` and so above xterm's
      // text-only one. `TerminalPasteIntent` is a type xterm has no entry for,
      // which is what lets an ancestor handle a chord dispatched from inside
      // the view — see the intent's own doc, and `pasteIntoTerminal` for what
      // the handler does that xterm's could not.
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
      // Desktop uses the physical keyboard; this also avoids xterm opening a
      // software text-input client, which on Windows fails with "Could not set
      // client, view ID is null" and blanks the terminal.
      hardwareKeyboardOnly: true,
      onKeyEvent: _onKeyEvent,
      // xterm's own shortcut manager runs after `onKeyEvent` and before
      // `Terminal.keyInput`; its Windows defaults quietly took Ctrl+A and
      // Ctrl+V from the shell. Ctrl+V is paste again, but declared — and so
      // switchable in Settings, which is what the overrides are doing here.
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
/// pointer. Names the gesture and the target — the *resolved* target, which for
/// a relative path is the one useful thing the pane knows and the output does
/// not say.
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
              // Ctrl on Windows and Linux, Cmd on macOS — both are accepted,
              // and the one named is the one the platform's users expect.
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

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'cast_recorder.dart';
import 'command_block_recorder.dart';
import 'pane_terminal.dart';
import 'scrollback_replay.dart';

/// One open terminal: a stable [id]/[title] and the xterm [Terminal] buffer the
/// UI renders. Implementations own whatever backs the buffer.
abstract class TerminalInstance {
  String get id;
  String get title;
  Terminal get terminal;

  /// The [TerminalProfile] id this pane was launched from — kept so the pane
  /// can be recreated after a restart.
  String get profileId;

  /// The directory the pane is in **now**: where it launched until the shell
  /// says it has moved (OSC 7). Live, because every reader wants the current
  /// answer rather than the launch one.
  String? get workingDirectory;

  /// [workingDirectory] as something to listen to. Notifies once per *change* —
  /// a shell that re-emits OSC 7 on every prompt redraw says nothing new.
  ValueListenable<String?> get directory;

  /// The agent CLI this pane runs, or `null` for a plain shell. Recorded rather
  /// than derived: a profile id cannot reproduce the exact command line.
  AgentPaneLaunch? get agentLaunch;

  /// Whether a process is running behind [terminal], and why not when there is
  /// none. Listenable, so a pane stops advertising itself as live on exit.
  ValueListenable<PaneLiveness> get liveness;

  /// The status the process exited with, once it has. Null while it runs, for a
  /// pane that never ran one, and for an instance that cannot know.
  int? get exitCode => null;

  /// Non-blank lines this shell printed **before the user ran anything in it** —
  /// its banner, MOTD and first prompt. Null until the user submits a line;
  /// `shouldDetachOnClose` uses it to tell a greeting from real history.
  int? get greetingLines => null;

  /// Drives selection/scroll for the view — read to copy the current selection.
  TerminalController get controller;

  /// Owned by the instance rather than the widget so the app can focus a pane
  /// and scroll it to a search hit without reaching into the widget tree.
  FocusNode get focusNode;
  ScrollController get scrollController;

  /// OSC 133 command boundaries, or `null` when the shell was not integrated.
  /// Null rather than an empty tracker, so the UI can tell the two apart.
  CommandBlockRecorder? get commandBlocks;

  /// Tears down the backing process/streams. Safe to call more than once.
  void dispose();
}

/// A [TerminalInstance] whose teardown outlives its `dispose()` — which stays
/// synchronous, so dropping this future on quit orphaned the pane's process.
abstract interface class ReapableTerminalInstance {
  /// Completes once the process tree behind this pane is gone. Already complete
  /// before [TerminalInstance.dispose] is called, so awaiting it is always safe.
  Future<void> get reaped;
}

/// A [TerminalInstance] whose session lives outside the app — in the server,
/// or on an SSH box the server relays — so quitting the app disconnects from
/// it and leaves it running.
abstract interface class HostedTerminalInstance {
  /// Whether there is a running session here that a quit would leave behind.
  bool get outlivesApp;

  /// Where it keeps running, as a sentence ends: "the session host".
  String get keptBy;

  /// Ends the session on the host for good. Closing a pane never does this.
  Future<void> endHostedSession();
}

/// A [TerminalInstance] whose output ingestion answers to how visible it is.
/// The controller sets the tier from the layout; a pane never chooses its own.
abstract interface class TieredTerminalInstance {
  /// How visible this pane is now.
  void setIngestTier(IngestTier tier);

  /// What it was last told.
  IngestTier get ingestTier;
}

/// A [TerminalInstance] that gives its scrollback back while it is cold: the
/// history lives here as encoded text, and the controller stores it verbatim.
abstract interface class ParkableTerminalInstance {
  /// The encoded window held in place of a parsed buffer, or `null` when this
  /// pane's scrollback is live.
  String? get parkedScrollback;
}

/// A [TerminalInstance] whose parsed buffer can be handed to its replacement,
/// saving a 10-25 ms codec round trip. `null` when the history is only text.
abstract interface class AdoptableTerminalInstance {
  /// The buffer holding this pane's history, or `null` when there is none to
  /// hand over.
  Terminal? get adoptableBuffer;
}

/// A [TerminalInstance] whose output can be taped. The tap is upstream of the
/// ingest tier: a cold pane's bytes never reach `terminal.write` at all.
abstract interface class RecordableTerminalInstance {
  /// Starts copying this pane's output into [recorder]. Replaces any recorder
  /// already attached.
  void startRecording(CastRecorder recorder);

  /// Stops copying. The recorder keeps what it has.
  void stopRecording();

  /// The recorder taping this pane, or null.
  CastRecorder? get recorder;
}

/// A [TerminalInstance] that can be handed a command before it is connected,
/// and types it at the prompt once there is one — **never submitted**: the
/// person reads it, presses Enter, and answers `sudo` in the real terminal.
abstract interface class PromptTypingTerminalInstance {
  void typeAtPrompt(String text);
}

/// A [ValueListenable] that holds one value and never notifies — what
/// [TerminalInstance.directory] is for a pane whose shell cannot report one.
class UnchangingValue<T> implements ValueListenable<T> {
  const UnchangingValue(this.value);

  @override
  final T value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// A pane's working directory: where it launched, then whatever OSC 7 says. A
/// [ValueNotifier], so a shell re-emitting the same path costs nothing.
class WorkingDirectoryTracker {
  WorkingDirectoryTracker(String? launchedIn, {String? hostname})
    : _hostname = hostname ?? localHostname,
      _directory = ValueNotifier(launchedIn);

  /// This machine's name, read once. Null when the host will not say, which
  /// makes every named host foreign — see [workingDirectoryFromOsc].
  static final String? localHostname = () {
    try {
      return Platform.localHostname;
    } catch (_) {
      return null;
    }
  }();

  final ValueNotifier<String?> _directory;
  final String? _hostname;
  bool _disposed = false;

  ValueListenable<String?> get listenable => _directory;

  String? get value => _directory.value;

  /// One OSC from the pane's [OscRouter]. `null` from the parser means *no
  /// answer*, never *the pane has no directory*.
  void handleOsc(String code, List<String> args) {
    if (_disposed) return;
    final reported = workingDirectoryFromOsc(code, args, hostname: _hostname);
    if (reported != null) _directory.value = reported;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _directory.dispose();
  }
}

/// Signature for creating a [TerminalInstance] — injected so tests can supply a
/// process-free fake (a real one asks the server for a terminal).
typedef TerminalInstanceFactory =
    TerminalInstance Function({
      required String id,
      required TerminalProfile profile,
      String? workingDirectory,
      String? restoredScrollback,
      bool shellIntegration,
      AgentPaneLaunch? agentLaunch,
      Terminal? adoptTerminal,
    });

/// Writes [scrollback] into [terminal] followed by a dim marker, so replayed
/// history is visibly separate. Does nothing when there is nothing to restore.
void writeRestoredScrollback(Terminal terminal, String? scrollback) {
  if (scrollback == null || scrollback.isEmpty) return;
  replayScrollback(terminal, scrollback);
  writeRestoreMarker(terminal);
}

/// Writes the dim marker that says where replayed history ends and the live
/// process begins. Its own function because an adopted buffer needs only this.
void writeRestoreMarker(Terminal terminal) {
  final at = DateTime.now();
  final stamp =
      '${at.year}-${_two(at.month)}-${_two(at.day)} '
      '${_two(at.hour)}:${_two(at.minute)}';
  terminal.write(
    '\r\n\x1b[90m\u2500\u2500 restored \u2500 $stamp '
    '\u2500\u2500\x1b[0m\r\n',
  );
}

String _two(int value) => value.toString().padLeft(2, '0');

/// A [TerminalInstance] that failed to spawn: it renders the error in its buffer
/// so the panel surfaces *why* instead of crashing the app.
class ErrorTerminalInstance implements TerminalInstance {
  ErrorTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required String message,
    this.workingDirectory,
    this.agentLaunch,
    String? restoredScrollback,
    Terminal? adoptTerminal,
  }) {
    // A failed *restart* still holds the history of the pane it replaced, and
    // that history is the reason anyone would retry.
    terminal =
        adoptTerminal ?? Terminal(maxLines: kErrorPaneScrollbackMaxLines);
    if (adoptTerminal == null) {
      writeRestoredScrollback(terminal, restoredScrollback);
    }
    terminal.write('\x1b[91m$message\x1b[0m\r\n');
  }

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  @override
  final String? workingDirectory;

  /// An error pane never started a shell, so nothing can ever report a `cd`.
  @override
  late final ValueListenable<String?> directory = UnchangingValue(
    workingDirectory,
  );

  @override
  final AgentPaneLaunch? agentLaunch;
  @override
  late final Terminal terminal;
  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();

  /// An error pane never runs a shell, so it never has command boundaries.
  @override
  CommandBlockRecorder? get commandBlocks => null;

  /// Nothing ran here, so nothing exited.
  @override
  int? get exitCode => null;

  // Nothing ever ran here, so there is no greeting to have measured.
  @override
  int? get greetingLines => null;

  /// Nothing is running: the spawn failed. The pane therefore offers the same
  /// "start it" affordance a restored pane does, which doubles as a retry.
  @override
  final ValueListenable<PaneLiveness> liveness = const _Constant(
    PaneLiveness.exited,
  );

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    focusNode.dispose();
    scrollController.dispose();
  }
}

/// A [ValueListenable] whose value never changes, so a pane with no process
/// does not have to own (and tear down) a notifier that can never fire.
class _Constant<T> implements ValueListenable<T> {
  const _Constant(this.value);

  @override
  final T value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// The grid the app last laid a restored pane out at, shared by all of them —
/// without it a pane parses at 80 columns and is reflowed in the same frame.
class TerminalGridHint {
  /// Null until the workbench has laid a restored pane out.
  ({int columns, int rows})? grid;
}

/// A [TerminalInstance] rebuilt from a stored record with **no process behind
/// it**: starting one would re-execute the launch command it recorded.
class DormantTerminalInstance
    implements TerminalInstance, AdoptableTerminalInstance {
  DormantTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required this.restoredScrollback,
    this.workingDirectory,
    this.agentLaunch,
    this.wasLive = false,
    this.gridHint,
  });

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  @override
  final String? workingDirectory;

  /// Whether this pane had a process behind it when the app last closed — kept
  /// so a tab opened later can start what was running in it.
  final bool wasLive;

  /// Replayed history with nothing running behind it: the directory it holds is
  /// the one the pane was last observed in, and nothing here can move it.
  @override
  late final ValueListenable<String?> directory = UnchangingValue(
    workingDirectory,
  );

  @override
  final AgentPaneLaunch? agentLaunch;

  /// The stored scrollback exactly as it was read back, so starting the pane
  /// replays precisely that — no second codec round trip, no duplicate marker.
  final String restoredScrollback;

  /// Where this pane reads — and reports — the size to parse at. Read at parse
  /// time, not construction: every pane is built before the layout exists.
  final TerminalGridHint? gridHint;

  /// Parsed only when something asks to see it: a restored layout can hold a
  /// hundred panes, most of which are never opened and never built at all.
  @override
  late final Terminal terminal = _buildTerminal();

  /// Whether anything has asked to see this pane yet — `late final` cannot be
  /// asked whether it has run. Read before [terminal] by anything that only
  /// wants to *observe* the pane: reading [terminal] would build it.
  bool get bufferBuilt => _bufferBuilt;
  bool _bufferBuilt = false;

  /// The buffer, but only once something has already built it: building one to
  /// hand over would *be* the parse this exists to avoid.
  @override
  Terminal? get adoptableBuffer =>
      _bufferBuilt && restoredScrollback.isNotEmpty ? terminal : null;

  Terminal _buildTerminal() {
    _bufferBuilt = true;
    final built = PaneTerminal(maxLines: kLiveScrollbackMaxLines)
      ..inputHandler = const KarmashalaInputHandler();
    final hint = gridHint;
    if (hint != null) {
      // Before the write, or the hint buys nothing: it is the *parse* that has
      // to happen at the width the text will be read at.
      if (hint.grid case (:final columns, :final rows)?) {
        built.resizeNow(columns, rows);
      }
      // Nothing else claims `onResize` here, so this pane can report what the
      // workbench laid it out at, for the next one to parse into.
      built.onResize = (columns, rows, _, _) =>
          hint.grid = (columns: columns, rows: rows);
    }
    if (restoredScrollback.isNotEmpty) {
      replayScrollback(built, restoredScrollback);
    }
    return built;
  }

  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();

  /// No process ever ran here, so there are no command boundaries — the stored
  /// scrollback is text, not a record of what produced it.
  @override
  CommandBlockRecorder? get commandBlocks => null;

  /// Nothing ran here, so nothing exited.
  @override
  int? get exitCode => null;

  // Nothing ever ran here, so there is no greeting to have measured.
  @override
  int? get greetingLines => null;

  @override
  final ValueListenable<PaneLiveness> liveness = const _Constant(
    PaneLiveness.restored,
  );

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    focusNode.dispose();
    scrollController.dispose();
  }
}

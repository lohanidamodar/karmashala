import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/command_block_recorder.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_codec.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_park.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import 'fake_instance.dart';

/// What **resuming a session** costs, counted rather than timed.
///
/// The owner's report against 1.1.4 was "lag is largest when resuming a
/// session", and resume is the one path that changed shape in that window:
/// until `cacf684`/`0711d28`, resuming a restored session opened a *second*
/// tab with an empty pane, so it parsed nothing. Resuming **into** the pane the
/// session already has is the right behaviour — one terminal for one session —
/// but it was paid for by rebuilding that pane's history from scratch:
/// `encodeScrollback` out of the old buffer, `Terminal.write` back into a new
/// one, up to [kDurableScrollbackMaxBytes] of SGR-dense text, synchronously on
/// the UI isolate.
///
/// Measured on the Loop 26 corpora at a full durable window (~256 KiB): the
/// replay parse cost **6-15 ms** and the layout save that immediately
/// follows re-encoded the same buffer for another **3-10 ms** — 10-25 ms of
/// main-isolate work per resume that 1.1.3 did not spend.
///
/// None of it was necessary. The pane being resumed into *already holds that
/// history, parsed*: the workbench built its buffer when it showed it. So the
/// buffer is handed to the pane that replaces it ([AdoptableTerminalInstance])
/// and the round trip does not happen at all.
///
/// These are the **counting** assertions for that, in the shape
/// `scale_curve_test.dart` established: characters handed to the parser, and
/// reads of the buffer by the encoder. A wall-clock number cannot be asserted
/// on a shared machine; a count of the work can.
void main() {
  /// A pane's worth of agent output — colourised, because that is what makes a
  /// stored scrollback big enough to be worth not parsing twice.
  String agentHistory(int lines) => [
    for (var i = 0; i < lines; i++)
      '\x1b[38;5;${(i % 200) + 16}m*\x1b[0m \x1b[1mUpdate\x1b[0m('
          'lib/src/features/terminal/data/file_$i.dart)  '
          '\x1b[2m+${i % 40} -${i % 7}\x1b[0m',
  ].join('\r\n');

  const launch = AgentPaneLaunch(
    agentId: 'claude',
    executable: 'claude',
    workingDirectory: r'C:\ws',
    sessionId: 'sess-1',
  );

  const resume = AgentPaneLaunch(
    agentId: 'claude',
    executable: 'claude',
    arguments: ['--resume', 'ext-1'],
    workingDirectory: r'C:\ws',
    sessionId: 'sess-1',
  );

  /// A container whose panes count what the parser and the encoder were given.
  ({ProviderContainer container, TerminalSessionsController controller}) open({
    AppDatabase? database,
  }) {
    final container = ProviderContainer(
      overrides: fakeTerminalOverrides(
        database: database,
        instanceFactory:
            ({
              required String id,
              required TerminalProfile profile,
              String? workingDirectory,
              String? restoredScrollback,
              bool shellIntegration = false,
              AgentPaneLaunch? agentLaunch,
              Terminal? adoptTerminal,
            }) => _CountingInstance(
              id: id,
              title:
                  agentLaunch?.title ?? agentLaunch?.agentId ?? profile.label,
              profileId: agentLaunch?.profileId ?? profile.id,
              workingDirectory: workingDirectory,
              agentLaunch: agentLaunch,
              restoredScrollback: restoredScrollback,
              adoptTerminal: adoptTerminal,
            ),
      ),
    );
    addTearDown(container.dispose);
    return (
      container: container,
      controller: container.read(terminalSessionsControllerProvider.notifier),
    );
  }

  /// A layout holding one agent pane with [lines] of history, saved and
  /// reopened — which is how a [DormantTerminalInstance] comes to exist.
  ({
    ProviderContainer container,
    TerminalSessionsController controller,
    String paneId,
    String stored,
  })
  restoredLayout({int lines = 2000}) {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final first = open(database: db);
    final opened = first.controller.openAgentTab(launch);
    first.controller
        .instanceFor(opened.paneId)!
        .terminal
        .write('${agentHistory(lines)}\r\n');
    first.controller.persistLayout();
    final stored = encodeScrollback(
      first.controller.instanceFor(opened.paneId)!.terminal,
    );
    first.container.dispose();

    final next = open(database: db);
    return (
      container: next.container,
      controller: next.controller,
      paneId: opened.paneId,
      stored: stored,
    );
  }

  _CountingInstance countingPane(
    TerminalSessionsController controller,
    String paneId,
  ) => controller.instanceFor(paneId)! as _CountingInstance;

  group('resuming a session the workbench is already showing', () {
    test('hands over the buffer instead of parsing the history again', () {
      final app = restoredLayout();
      final dormant =
          app.controller.instanceFor(app.paneId)! as DormantTerminalInstance;
      // What the workbench does the moment it draws a restored pane, and the
      // reason there is a parsed buffer to hand over at all.
      final shown = dormant.terminal;
      expect(dormant.bufferBuilt, isTrue);
      // What 1.1.4 parsed a second time, and the control this is measured
      // against.
      final dormantLines = shown.buffer.lines.length;

      app.controller.startAgentInPane(app.paneId, resume);

      final started = countingPane(app.controller, app.paneId);
      // ignore: avoid_print
      print(
        'resume: ${app.stored.length} chars of stored scrollback, '
        '${started.linesParsed} lines parsed by the pane that replaced it '
        '(1.1.4 parsed all $dormantLines of them)',
      );
      expect(
        started.adopted,
        same(shown),
        reason:
            'the session resumes into the buffer it was already looking at, '
            'not a copy of it rebuilt from text',
      );
      expect(
        started.linesParsed,
        lessThanOrEqualTo(2),
        reason:
            'the only thing written into an adopted buffer is the restore '
            'marker; the history is already in it, and this count is what has '
            'to stay flat as the stored window grows',
      );
      expect(dormantLines, greaterThan(1000), reason: 'the control');
    });

    test('the history is still on screen afterwards', () {
      final app = restoredLayout(lines: 50);
      // Shown, so there is a buffer to adopt.
      app.controller.instanceFor(app.paneId)!.terminal;

      final tabId = app.controller.startAgentInPane(app.paneId, resume);

      final state = app.container.read(terminalSessionsControllerProvider);
      // The robustness bar: one session, one terminal, in the tab it was in.
      expect(tabId, state.tabs.single.id);
      expect(state.tabs.single.layout.panes, [app.paneId]);
      expect(state.livenessOf(app.paneId), PaneLiveness.live);

      final started = countingPane(app.controller, app.paneId);
      final text = started.terminal.mainBuffer.getText();
      expect(text, contains('file_49.dart'));
      expect(
        text,
        contains('restored'),
        reason: 'the marker still says where the replayed history ends',
      );
      expect(started.agentLaunch!.arguments, ['--resume', 'ext-1']);
    });
  });

  test('a dormant pane nobody has looked at still replays its text', () {
    final app = restoredLayout(lines: 50);
    final dormant =
        app.controller.instanceFor(app.paneId)! as DormantTerminalInstance;
    expect(dormant.bufferBuilt, isFalse);

    app.controller.startAgentInPane(app.paneId, resume);

    expect(
      dormant.bufferBuilt,
      isFalse,
      reason:
          'building a buffer in order to hand it over would be exactly the '
          'parse this exists to avoid',
    );
    final started = countingPane(app.controller, app.paneId);
    expect(started.adopted, isNull);
    expect(started.terminal.mainBuffer.getText(), contains('file_49.dart'));
  });

  test('restarting a pane whose process exited neither encodes nor parses', () {
    // No database: nothing else can read the buffer, so the encoder's reads are
    // exactly what the restart spent.
    final app = open();
    final tabId = app.controller.openTab(TerminalProfile.powerShell);
    final paneId = app.container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((t) => t.id == tabId)
        .layout
        .panes
        .single;
    final pane = countingPane(app.controller, paneId);
    pane.terminal.write('${agentHistory(500)}\r\n');
    final shown = pane.terminal as _CountingTerminal;
    pane.exitCleanly();
    final encodesBefore = shown.mainBufferReads;

    app.controller.startPane(paneId);

    final started = countingPane(app.controller, paneId);
    expect(started.adopted, same(shown));
    expect(
      shown.mainBufferReads,
      encodesBefore,
      reason:
          'the buffer is handed over, so nothing encodes it out only to parse '
          'the same text straight back in',
    );
    expect(started.linesParsed, lessThanOrEqualTo(2));
    expect(started.terminal.mainBuffer.getText(), contains('file_499.dart'));
  });

  test('a parked pane still replays its text, because its buffer is not the '
      'history', () {
    final app = open();
    final tabId = app.controller.openTab(TerminalProfile.powerShell);
    final paneId = app.container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((t) => t.id == tabId)
        .layout
        .panes
        .single;
    final pane = countingPane(app.controller, paneId);
    pane.terminal.write('${agentHistory(300)}\r\n');
    // A second tab, so closing the first leaves a tab to be active in.
    app.controller.openTab(TerminalProfile.commandPrompt);
    // Detaching parks the scrollback: the buffer keeps only the screen, and the
    // history moves into the parked window.
    app.controller.closeTab(tabId);
    expect(pane.parkedScrollback, isNotNull);
    pane.exitCleanly();

    app.controller.startPane(paneId);

    final started = countingPane(app.controller, paneId);
    expect(
      started.adopted,
      isNull,
      reason: 'a parked pane gave its buffer up; the text is the history',
    );
    expect(started.terminal.mainBuffer.getText(), contains('file_299.dart'));
  });
}

/// A process-free pane that counts what the parser and the encoder were given.
///
/// `Terminal.mainBuffer` is the codec's single entry point into the buffer, so
/// counting reads of it *is* the encode count — the same probe
/// `layout_save_cost_test.dart` uses. `charsParsed` is the other half: what
/// a new pane had to hand to the VT parser in order to hold its history.
class _CountingInstance
    implements
        TerminalInstance,
        TieredTerminalInstance,
        ParkableTerminalInstance,
        AdoptableTerminalInstance {
  _CountingInstance({
    required this.id,
    required this.title,
    required this.profileId,
    this.workingDirectory,
    this.agentLaunch,
    String? restoredScrollback,
    Terminal? adoptTerminal,
  }) : adopted = adoptTerminal {
    terminal = adopted ?? (_CountingTerminal()..resize(120, 40));
    // A delta, because an adopted buffer arrives with the previous pane's
    // history already in it and what is being measured is what *this* pane had
    // to put there. Lines rather than characters: an adopted buffer is not a
    // [_CountingTerminal] — it belongs to whichever pane built it — and the
    // buffer's own size is a count every terminal can answer.
    final before = terminal.buffer.lines.length;
    // The shape [PtyTerminalInstance] has: an adopted buffer is the history
    // already and takes only the marker.
    if (adopted == null) {
      writeRestoredScrollback(terminal, restoredScrollback);
    } else {
      writeRestoreMarker(terminal);
    }
    linesParsed = terminal.buffer.lines.length - before;
  }

  /// The buffer this pane was handed rather than text, if it was.
  final Terminal? adopted;

  /// Lines this pane had to put into a buffer in order to hold its history.
  late final int linesParsed;

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  @override
  final String? workingDirectory;

  /// Never moves: nothing runs here to report a `cd`.
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
  @override
  CommandBlockRecorder? get commandBlocks => null;
  @override
  int? exitCode;

  @override
  int? greetingLines;

  @override
  ValueListenable<PaneLiveness> get liveness => _liveness;
  final _liveness = ValueNotifier(PaneLiveness.live);

  /// Parks and unparks through the real [ScrollbackPark], so a detached pane in
  /// this file behaves as one does everywhere else.
  late final ScrollbackPark park = ScrollbackPark(terminal);

  @override
  String? get parkedScrollback => park.parked;

  @override
  Terminal? get adoptableBuffer =>
      !_liveness.value.isLive && !park.isParked ? terminal : null;

  /// Storage is real, as it is for [FakeTerminalInstance]: a pane this file
  /// detaches has to park for the same reason a real one does, or the parked
  /// case below would be testing nothing.
  @override
  IngestTier ingestTier = IngestTier.hot;

  @override
  void setIngestTier(IngestTier tier) {
    if (ingestTier == tier) return;
    final wasCold = ingestTier == IngestTier.cold;
    ingestTier = tier;
    if (tier == IngestTier.cold) {
      park.park();
    } else if (wasCold) {
      park.unpark();
    }
  }

  /// Ends this pane the way a shell that was typed `exit` at ends.
  void exitCleanly() {
    exitCode = 0;
    _liveness.value = PaneLiveness.exited;
  }

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _liveness.value = PaneLiveness.exited;
    _liveness.dispose();
    focusNode.dispose();
    scrollController.dispose();
  }
}

class _CountingTerminal extends Terminal {
  _CountingTerminal() : super(maxLines: kLiveScrollbackMaxLines);

  int charsWritten = 0;
  int mainBufferReads = 0;

  @override
  void write(String data) {
    charsWritten += data.length;
    super.write(data);
  }

  @override
  Buffer get mainBuffer {
    mainBufferReads++;
    return super.mainBuffer;
  }
}

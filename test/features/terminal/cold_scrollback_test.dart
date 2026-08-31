import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_instance.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_grid_text.dart';
import 'package:chitragupta/src/features/terminal/domain/ingest_tier.dart';
import 'package:chitragupta/src/features/terminal/domain/scrollback_limits.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// A detached pane gives its parsed scrollback back and holds the history as
/// text instead. What must not change is anything the user can see: the
/// session's history has to survive a restart, come back when the session does,
/// and stay readable to the status sources while it is away.
void main() {
  ({ProviderContainer container, TerminalSessionsController controller}) open({
    AppDatabase? database,
  }) {
    final container = fakeTerminalContainer(database: database);
    addTearDown(container.dispose);
    return (
      container: container,
      controller: container.read(terminalSessionsControllerProvider.notifier),
    );
  }

  String onlyPaneOf(ProviderContainer container, String tabId) => container
      .read(terminalSessionsControllerProvider)
      .tabs
      .firstWhere((t) => t.id == tabId)
      .layout
      .panes
      .single;

  /// A pane with real history behind it — an idle shell is released on close
  /// rather than detached, so there would be nothing to park.
  void fill(TerminalInstance instance, int lines) {
    for (var i = 0; i < lines; i++) {
      instance.terminal.write('output line $i\r\n');
    }
  }

  test('detaching parks the scrollback and keeps the screen', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    final instance =
        app.controller.instanceFor(paneId)! as FakeTerminalInstance;
    fill(instance, 200);
    final linesBefore = instance.terminal.mainBuffer.lines.length;

    app.controller.closeTab(first);

    expect(instance.ingestTier, IngestTier.cold);
    expect(instance.parkedScrollback, contains('output line 199'));
    expect(instance.terminal.mainBuffer.lines.length, lessThan(linesBefore));
  });

  test('a parked pane still reads as a session to the status sources', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    final instance = app.controller.instanceFor(paneId)!;
    fill(instance, 200);
    instance.terminal.write('Do you want to proceed?\r\n');

    app.controller.closeTab(first);

    // `terminalTailLines` is the third status source; a background session must
    // not go dark for it just because nobody has a tab open on it.
    expect(
      terminalTailLines(instance.terminal).join('\n'),
      contains('Do you want to proceed?'),
    );
  });

  test('reattaching brings the recent window back', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    final instance = app.controller.instanceFor(paneId)!;
    fill(instance, 200);

    app.controller.closeTab(first);
    app.controller.reattachSession(paneId);

    final text = instance.terminal.mainBuffer.getText();
    expect(text, contains('output line 199'));
    expect(text, contains('output line 100'));
    expect((instance as FakeTerminalInstance).parkedScrollback, isNull);
  });

  test('a detached session keeps its scrollback across a restart', () {
    final database = AppDatabase.memory();
    addTearDown(database.close);

    final app = open(database: database);
    final first = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    fill(app.controller.instanceFor(paneId)!, 200);

    // Closing the tab detaches; persisting it is what the next launch reads.
    app.controller.closeTab(first);
    app.controller.persistWorkspace();
    app.container.dispose();

    final next = open(database: database);
    final restored = next.container.read(terminalSessionsControllerProvider);
    expect(restored.detached.single.paneId, paneId);
    final dormant =
        next.controller.instanceFor(paneId)! as DormantTerminalInstance;
    expect(dormant.restoredScrollback, contains('output line 199'));
  });

  test(
    'the autosave stores a parked pane without re-encoding an empty buffer',
    () {
      final database = AppDatabase.memory();
      addTearDown(database.close);

      final app = open(database: database);
      final first = app.controller.openTab(TerminalProfile.powerShell);
      app.controller.openTab(TerminalProfile.commandPrompt);
      final paneId = onlyPaneOf(app.container, first);
      fill(app.controller.instanceFor(paneId)!, 200);

      app.controller.closeTab(first);
      // Dirty it again the way the autosave tick would find it.
      app.controller.saveDirtyScrollback();
      app.controller.persistWorkspace();
      app.container.dispose();

      final next = open(database: database);
      final dormant =
          next.controller.instanceFor(paneId)! as DormantTerminalInstance;
      expect(dormant.restoredScrollback, contains('output line 199'));
    },
  );

  test('a restored pane nobody opens never parses its scrollback', () {
    final database = AppDatabase.memory();
    addTearDown(database.close);

    final app = open(database: database);
    app.controller.openTab(TerminalProfile.powerShell);
    final tabs = app.container.read(terminalSessionsControllerProvider).tabs;
    fill(app.controller.instanceFor(tabs.single.layout.panes.single)!, 200);
    app.controller.persistWorkspace();
    app.container.dispose();

    final next = open(database: database);
    final restored = next.container.read(terminalSessionsControllerProvider);
    final paneId = restored.tabs.single.layout.panes.single;
    final dormant =
        next.controller.instanceFor(paneId)! as DormantTerminalInstance;

    expect(
      dormant.bufferBuilt,
      isFalse,
      reason:
          'a hundred restored panes must not cost a hundred parses at '
          'launch for tabs nobody has looked at',
    );

    // Saving the workspace again round-trips the stored text rather than
    // building the buffer to re-encode it.
    next.controller.persistWorkspace();
    expect(dormant.bufferBuilt, isFalse);

    // And it is still there when something does look.
    expect(dormant.terminal.buffer.getText(), contains('output line 199'));
    expect(dormant.bufferBuilt, isTrue);
  });

  test('a detached pane that says something is still heard', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    final instance =
        app.controller.instanceFor(paneId)! as FakeTerminalInstance;
    fill(instance, 200);
    app.controller.closeTab(first);

    // The case the tiers introduced and the one the scale target is made of:
    // an agent whose tab was closed reaches an approval prompt. Nothing is
    // watching it draw, and the grid source is exactly what is meant to notice.
    instance.receive('Do you want to proceed?\r\n');

    expect(
      terminalTailLines(instance.terminal).join('\n'),
      contains('Do you want to proceed?'),
      reason: 'a session with no tab is the session nobody is watching for',
    );
    expect(
      instance.terminal.mainBuffer.lines.length,
      lessThanOrEqualTo(instance.terminal.viewHeight),
      reason: 'and it cost the screen it already had, not the buffer it gave up',
    );
  });

  test('coming back replays what was missed once, not twice', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    final instance =
        app.controller.instanceFor(paneId)! as FakeTerminalInstance;
    fill(instance, 200);
    app.controller.closeTab(first);
    instance.receive('while detached\r\n');

    app.controller.reattachSession(paneId);

    final text = instance.terminal.mainBuffer.getText();
    expect(
      'while detached'.allMatches(text).length,
      1,
      reason:
          'the screen refresh and the spool replay are the same bytes; the '
          'unpark clears the buffer so only one of them survives',
    );
    expect(text, contains('output line 199'), reason: 'history came back too');
  });

  test('a pane promoted and demoted a hundred times holds nothing extra', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    final second = app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    final instance =
        app.controller.instanceFor(paneId)! as FakeTerminalInstance;
    fill(instance, 200);

    for (var cycle = 0; cycle < 100; cycle++) {
      app.controller.closeTab(first);
      instance.receive('cycle $cycle\r\n');
      app.controller.reattachSession(paneId);
      app.controller.activateTab(second);
      app.controller.activateTab(
        app.container.read(terminalSessionsControllerProvider).tabs.first.id,
      );
    }

    expect(instance.spool.length, 0, reason: 'nothing left spooled');
    expect(instance.coldScreen.pendingBytes, 0);
    expect(instance.parkedScrollback, isNull, reason: 'it is not cold now');
    expect(
      instance.terminal.mainBuffer.lines.length,
      lessThanOrEqualTo(kColdScrollbackMaxLines + instance.terminal.viewHeight),
      reason:
          'each cycle rebuilds a bounded window; a hundred of them must not '
          'be a hundred windows stacked on each other',
    );
    expect(
      instance.terminal.mainBuffer.getText(),
      contains('cycle 99'),
      reason: 'and the pane is still correct at the end of it',
    );
  });
}

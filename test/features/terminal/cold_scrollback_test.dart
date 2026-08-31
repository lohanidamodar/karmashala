import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_instance.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_grid_text.dart';
import 'package:chitragupta/src/features/terminal/domain/ingest_tier.dart';
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
}

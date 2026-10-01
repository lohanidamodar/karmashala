import 'package:karmashala_terminal_runtime/persistence.dart';
import 'package:karmashala/src/features/sessions/application/session_resume_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// **Scrollback a window holds, and what it lets go of.**
///
/// A pane kept with no tab used to go cold: its parsed scrollback given back
/// and held as text. Since 2026-09-30 there is no such pane — closing a tab
/// drops it, and the server keeps the terminal and its history — so a closed
/// tab must hold nothing here: no buffer, no parked text, no stored row. What
/// a restored tab may not cost (a parse nobody asked for) is unchanged.
void main() {
  ({ProviderContainer container, TerminalSessionsController controller}) open({
    TerminalLayoutStore? database,
  }) {
    final container = fakeTerminalContainer(layoutStore: database);
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

  test('closing a tab drops its pane and parks nothing', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    final instance =
        app.controller.instanceFor(paneId)! as FakeTerminalInstance;
    fill(instance, 200);

    app.controller.closeTab(first);

    expect(app.controller.instanceFor(paneId), isNull);
    expect(instance.disposed, isTrue);
    expect(instance.ingestTier, isNot(IngestTier.cold));
    expect(instance.parkedScrollback, isNull);
  });

  test('a closed tab is not a session the status sources read', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    fill(app.controller.instanceFor(paneId)!, 200);

    app.controller.closeTab(first);

    // The server's reading of that terminal is the status source now; this
    // window has no pane for it to go dark or stay lit in.
    final state = app.container.read(terminalSessionsControllerProvider);
    expect(state.detached, isEmpty);
    expect(state.liveness, isNot(contains(paneId)));
  });

  test('a closed tab\'s scrollback is not kept across a restart', () {
    final database = TerminalLayoutStore.memory();
    addTearDown(database.close);

    final app = open(database: database);
    final first = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    fill(app.controller.instanceFor(paneId)!, 200);

    app.controller.closeTab(first);
    app.controller.persistLayout();
    app.container.dispose();

    final next = open(database: database);
    final restored = next.container.read(terminalSessionsControllerProvider);
    expect(restored.detached, isEmpty);
    expect(restored.tabs, hasLength(1), reason: 'the tab still open');
    expect(next.controller.instanceFor(paneId), isNull);
  });

  test('the autosave after a close stores nothing for the dropped pane', () {
    final database = TerminalLayoutStore.memory();
    addTearDown(database.close);

    final app = open(database: database);
    final first = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final paneId = onlyPaneOf(app.container, first);
    fill(app.controller.instanceFor(paneId)!, 200);

    app.controller.closeTab(first);
    // What the autosave tick would find: nothing of that pane is dirty.
    expect(app.controller.saveDirtyScrollback(), isNot(contains(paneId)));
    app.controller.persistLayout();
    app.container.dispose();

    final next = open(database: database);
    expect(next.controller.instanceFor(paneId), isNull);
  });

  test('a restored pane nobody opens never parses its scrollback', () {
    final database = TerminalLayoutStore.memory();
    addTearDown(database.close);

    final app = open(database: database);
    // Two tabs, and the interesting one is the tab that is *not* in front: a
    // launch now puts the active tab's panes back to work, and this is the
    // property that keeps the other ninety-nine free — see
    // `pane_restart_on_launch_test.dart`.
    final background = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.openTab(TerminalProfile.commandPrompt);
    final backgroundPane = onlyPaneOf(app.container, background);
    fill(app.controller.instanceFor(backgroundPane)!, 200);
    app.controller.persistLayout();
    app.container.dispose();

    final next = open(database: database);
    final dormant =
        next.controller.instanceFor(backgroundPane)! as DormantTerminalInstance;

    expect(
      dormant.bufferBuilt,
      isFalse,
      reason:
          'a hundred restored panes must not cost a hundred parses at '
          'launch for tabs nobody has looked at',
    );

    // Saving the layout again round-trips the stored text rather than
    // building the buffer to re-encode it.
    next.controller.persistLayout();
    expect(dormant.bufferBuilt, isFalse);

    // And it is still there when something does look.
    expect(dormant.terminal.buffer.getText(), contains('output line 199'));
    expect(dormant.bufferBuilt, isTrue);
  });

  test('asking where a restored agent pane is does not parse its buffer', () {
    // `sessionWhereaboutsProvider` reads a pane's last lines to spot an agent
    // refusing to resume a conversation another process holds — and it did
    // that for *any* non-live pane, which for a restored one is the whole
    // stored scrollback, parsed on every Explorer tap. It is also the wrong
    // question there: that text is the previous run's, so a refusal in it says
    // nothing about who holds the conversation now.
    final database = TerminalLayoutStore.memory();
    addTearDown(database.close);

    final app = open(database: database);
    final opened = app.controller.openAgentTab(
      const AgentPaneLaunch(
        agentId: 'claude',
        executable: 'claude',
        title: 'a session',
      ),
    );
    fill(app.controller.instanceFor(opened.paneId)!, 200);
    app.controller.persistLayout();
    app.container.dispose();

    final next = open(database: database);
    final paneId = next.container
        .read(terminalSessionsControllerProvider)
        .tabs
        .single
        .layout
        .panes
        .single;
    final dormant =
        next.controller.instanceFor(paneId)! as DormantTerminalInstance;
    expect(dormant.agentLaunch, isNotNull, reason: 'restored as an agent pane');

    expect(next.container.read(_conflictProbe(paneId)), isFalse);
    expect(dormant.bufferBuilt, isFalse);
  });

  test('a tab closed and reopened a hundred times holds nothing extra', () {
    final app = open();
    final second = app.controller.openTab(TerminalProfile.commandPrompt);
    final dropped = <FakeTerminalInstance>[];

    for (var cycle = 0; cycle < 100; cycle++) {
      final tab = app.controller.openTab(TerminalProfile.powerShell);
      final instance =
          app.controller.instanceFor(onlyPaneOf(app.container, tab))!
              as FakeTerminalInstance;
      fill(instance, 200);
      instance.receive('cycle $cycle\r\n');
      app.controller.closeTab(tab);
      app.controller.activateTab(second);
      dropped.add(instance);
    }

    final state = app.container.read(terminalSessionsControllerProvider);
    expect(state.tabs.single.id, second);
    expect(state.detached, isEmpty);
    expect(
      dropped.where((instance) => !instance.disposed),
      isEmpty,
      reason: 'every closed pane let go of its buffer',
    );
    expect(
      dropped.where((instance) => instance.parkedScrollback != null),
      isEmpty,
    );
  });
}

/// `paneShowsResumeConflict` takes a `Ref`, so a provider is how a test asks
/// it the question the Explorer asks.
final _conflictProbe = Provider.family<bool, String>(
  (ref, paneId) => paneShowsResumeConflict(ref, paneId),
);

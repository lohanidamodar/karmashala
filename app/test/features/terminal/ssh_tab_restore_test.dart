import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show TerminalRecord;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_runtime/persistence.dart';

import '../../support/fake_data_server.dart';
import 'fake_instance.dart';

/// A tab on an SSH machine comes back after a quit, on the box session it
/// left running (owner, 2026-10-01: every launch started a new shell on DO
/// while the one the last tab showed ran on with no pane).
void main() {
  late Directory home;
  late int starts;
  late FakeDataServer data;

  setUp(() {
    // Short: a unix socket path must fit in 104 bytes on macOS.
    home = Directory.systemTemp.createTempSync('kss');
    starts = 0;
    data = FakeDataServer();
  });
  tearDown(() {
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // A socket node can still be held on Windows.
    }
  });

  Future<ProviderContainer> relaunch(TerminalLayoutStore db) async {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(layoutStore: db, data: await data.override()),
        localHostSessionAccessProvider.overrideWithValue(
          LocalHostSessionAccess(
            paths: HostPaths(Directory('${home.path}/.k'))..ensureDirectory(),
            executable: LocalHostExecutable(executableDirectory: home.path),
            startServe: (_) async {
              starts++;
              throw StateError('a restore started a host');
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Quits with [profiles] open as tabs, the last in front; their pane ids.
  List<String> quitWith(
    TerminalLayoutStore db,
    List<TerminalProfile> profiles,
  ) {
    final container = fakeTerminalContainer(layoutStore: db);
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final panes = <String>[];
    for (final profile in profiles) {
      final tabId = controller.openTab(profile);
      panes.add(
        container
            .read(terminalSessionsControllerProvider)
            .tabs
            .firstWhere((t) => t.id == tabId)
            .layout
            .panes
            .single,
      );
    }
    // What quitting does: the teardown save, then the processes.
    controller.persistLayout();
    container.dispose();
    return panes;
  }

  test('an SSH tab open at quit comes back and attaches to its box '
      'session; nothing new is opened', () async {
    final db = TerminalLayoutStore.memory();
    addTearDown(db.close);
    final pane = quitWith(db, [
      TerminalProfile.ssh('h1', hostName: 'DO'),
    ]).single;

    final next = await relaunch(db);
    final state = next.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(1), reason: 'the tab is restored');
    expect(state.tabs.single.layout.panes, [pane]);

    final instance = next
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(pane);
    expect(instance, isA<HostTerminalInstance>());
    final host = instance! as HostTerminalInstance;
    expect(host.sessionId, 'ssh:h1/karmashala_local_$pane');
    expect(host.attachOnly, isTrue);
    expect(host.profileId, 'ssh:h1');

    await next
        .read(terminalSessionsControllerProvider.notifier)
        .hostSurvivorsReattached;
    expect(data.terminals.opened, isEmpty, reason: 'attach only');
    expect(starts, 0);
  });

  test('a background SSH tab whose box session still runs is re-attached, '
      'not left as history', () async {
    final db = TerminalLayoutStore.memory();
    addTearDown(db.close);
    final panes = quitWith(db, [
      TerminalProfile.ssh('h1', hostName: 'DO'),
      TerminalProfile.powerShell,
    ]);
    final background = panes.first;
    final ref = 'ssh:h1/karmashala_local_$background';
    data.terminals.records[ref] = TerminalRecord(
      sessionId: ref,
      paneId: background,
      profileId: 'ssh:h1',
      title: 'DO',
      startedAt: DateTime.utc(2026),
    );

    final next = await relaunch(db);
    final controller = next.read(terminalSessionsControllerProvider.notifier);
    expect(next.read(terminalSessionsControllerProvider).tabs, hasLength(2));
    expect(controller.instanceFor(background), isA<DormantTerminalInstance>());

    await controller.hostSurvivorsReattached;

    final instance = controller.instanceFor(background);
    expect(instance, isA<HostTerminalInstance>());
    expect((instance! as HostTerminalInstance).sessionId, ref);
    expect((instance as HostTerminalInstance).attachOnly, isTrue);
    expect(data.terminals.opened, isEmpty);
    expect(starts, 0);
  });
}

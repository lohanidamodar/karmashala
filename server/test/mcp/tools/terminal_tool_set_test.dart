import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/mcp/tools/terminal_tool_schemas.dart';
import 'package:karmashala_host/src/mcp/tools/terminal_tool_set.dart';
import 'package:karmashala_host/src/pty/fake_pty.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Slice 5b: the terminal tools run in the server over its own terminals. A
/// window is only asked to show or close a tab, and with no window the tools
/// work the same and say nobody sees them.
void main() {
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late ServerTerminals terminals;
  late AppDatabase database;
  late DataService data;
  late TerminalToolSet tools;
  var ids = 0;

  setUp(() {
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher, hostname: 'this-mac');
    terminals = ServerTerminals(
      registry: registry,
      environments: () => const [],
      tell: (_) {},
      hostEnvironment: const {'SHELL': '/bin/zsh'},
      installedShells: () => const ['/bin/bash', '/bin/zsh'],
      windows: false,
      settle: Duration.zero,
    );
    database = AppDatabase.memory();
    data = DataService(database);
    ids = 0;
    tools = TerminalToolSet(
      terminals: terminals,
      registry: registry,
      data: data,
      newPaneId: () => 'pane${++ids}',
    );
  });

  tearDown(() async {
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await terminals.dispose();
    database.close();
  });

  Future<Map<String, Object?>> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
  ]) async =>
      (await tools.call(tool, arguments, null))! as Map<String, Object?>;

  /// A desktop client, subscribed, and what it is told.
  List<DataChange> window() {
    final told = <DataChange>[];
    data
        .open((batch) => told.addAll(batch.changes))
        .handle(const DataSubscribe());
    return told;
  }

  test('serves the five terminal tools, and nothing else', () {
    expect(tools.schemas, same(terminalControlToolSchemas));
    expect(tools.schemas.map((s) => s['name']), [
      'terminal_list',
      'terminal_open',
      'terminal_run',
      'terminal_output',
      'terminal_close',
    ]);
    expect(tools.call('session_send', const {}, null), isNull);
  });

  test('terminal_open starts a shell in the server and asks the window '
      'to show it', () async {
    final told = window();
    final opened = await call('terminal_open', {
      'profileId': 'posix:/bin/bash',
      'workingDirectory': '/src/app',
    });
    expect(opened['paneId'], 'pane1');
    expect(opened['tabId'], 'pane1');
    expect(opened['profileId'], 'posix:/bin/bash');
    expect(opened['shown'], isTrue);
    expect(launcher.started.single.argv, ['/bin/bash']);
    expect(launcher.started.single.workingDirectory, '/src/app');
    final intent = told.whereType<OpenTerminalTab>().single;
    expect(intent.paneId, 'pane1');
  });

  test('with no window open, terminal_open still opens the terminal and '
      'says nobody sees it — at once', () async {
    final opened = await call(
      'terminal_open',
    ).timeout(const Duration(seconds: 2));
    expect(opened['shown'], isFalse);
    expect(opened['note'], kTerminalNoWindowNote);
    expect(registry.find('karmashala_local_pane1'), isNotNull);
  });

  test('an unknown profile is refused, never substituted', () async {
    await expectLater(
      call('terminal_open', {'profileId': 'wsl:Ubuntu'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains(
            'No terminal profile "wsl:Ubuntu". Available: '
            'posix:/bin/zsh, posix:/bin/bash.',
          ),
        ),
      ),
    );
    expect(launcher.started, isEmpty);
  });

  test('terminal_list lists each terminal as a tab of one pane, the focused '
      'one active, and nothing detached', () async {
    window();
    await call('terminal_open');
    await call('terminal_open');
    final link = data.open((_) {});
    link.handle(const DataSubscribe());
    link.handle(const ClientActive(focusedPaneId: 'pane2'));
    launcher.handles.first.emit(utf8.encode('\x1b]7;file://this-mac/tmp\x07'));
    await pumpEventQueue();

    final listed = await call('terminal_list');
    expect(listed['activeTabId'], 'pane2');
    final tabs = (listed['tabs']! as List).cast<Map<String, Object?>>();
    expect(tabs.map((t) => t['id']), ['pane1', 'pane2']);
    expect(tabs.map((t) => t['active']), [false, true]);
    final pane = (tabs.first['panes']! as List).single as Map;
    expect(pane['paneId'], 'pane1');
    expect(pane['live'], isTrue);
    expect(pane['workingDirectory'], '/tmp');
    expect(listed['detached'], isEmpty);
    expect((listed['profiles']! as List).map((p) => (p as Map)['id']), [
      'posix:/bin/zsh',
      'posix:/bin/bash',
    ]);
  });

  test('terminal_output reads the server\'s own screen', () async {
    await call('terminal_open');
    launcher.handles.single.emit(utf8.encode('one\r\ntwo\r\nthree\r\n'));
    await pumpEventQueue();
    final output = await call('terminal_output', {
      'paneId': 'pane1',
      'lines': 3,
    });
    expect(output['live'], isTrue);
    expect(output['lines'], contains('three'));
    await expectLater(
      call('terminal_output', {'paneId': 'nope'}),
      throwsA(isA<StateError>()),
    );
  });

  group('terminal_close', () {
    test('a shell with history is detached: its tab closes, and it keeps '
        'running in the server', () async {
      final told = window();
      await call('terminal_open');
      final pty = launcher.handles.single;
      pty.emit(utf8.encode('\x1b]133;A\x07\$ \x1b]133;B\x07ls\r\n'));
      pty.emit(utf8.encode('\x1b]133;C\x07a b c\r\n\x1b]133;D;0\x07\$ '));
      await pumpEventQueue();

      final closed = await call('terminal_close', {'tabId': 'pane1'});
      final pane = (closed['panes']! as List).single as Map;
      expect(pane['outcome'], contains('detached'));
      expect(
        registry.find('karmashala_local_pane1')!.lifecycle.hasEnded,
        isFalse,
      );
      expect(told.whereType<CloseTerminalTab>().single.paneId, 'pane1');
      expect(pty.signals, isEmpty);
    });

    test('an idle shell that printed nothing is ended', () async {
      await call('terminal_open');
      final pty = launcher.handles.single;
      pty.emit(utf8.encode('\$ '));
      await pumpEventQueue();
      final closing = call('terminal_close', {'tabId': 'pane1'});
      await pumpEventQueue();
      pty.finish(0);
      final closed = await closing;
      final pane = (closed['panes']! as List).single as Map;
      expect(pane['outcome'], 'ended');
      expect(terminals.records, isEmpty);
    });

    test('kill ends whatever runs', () async {
      await call('terminal_open');
      final pty = launcher.handles.single;
      pty.emit(utf8.encode('lots of output\r\n'));
      await pumpEventQueue();
      final closing = call('terminal_close', {'tabId': 'pane1', 'kill': true});
      await pumpEventQueue();
      pty.finish(0);
      final closed = await closing;
      expect(((closed['panes']! as List).single as Map)['outcome'], 'ended');
    });

    test('an unknown tab is refused', () async {
      await expectLater(
        call('terminal_close', {'tabId': 'nope'}),
        throwsA(isA<StateError>()),
      );
    });
  });
}

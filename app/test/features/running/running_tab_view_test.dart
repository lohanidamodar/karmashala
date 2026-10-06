import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_routes.dart';
import 'package:karmashala/src/app/shell/running_tab_view.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/features/browser/application/browser_pane_controller.dart';
import 'package:karmashala/src/features/environments/application/environment_providers.dart';
import 'package:karmashala/src/features/environments/application/environments_controller.dart';
import 'package:karmashala/src/features/git/application/remote_links.dart';
import 'package:karmashala/src/features/running/application/running_providers.dart';
import 'package:karmashala/src/features/running/domain/port_label.dart';
import 'package:karmashala/src/features/sessions/application/background_runs_providers.dart';
import 'package:karmashala/src/features/terminal/data/terminals_client.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// The server's terminals, answering the Running tab's two requests only.
class _Terminals implements TerminalsClient {
  _Terminals(this.reading);

  RunningReading reading;
  int reads = 0;
  final stopped = <int>[];

  @override
  Future<RunningReading> running() async {
    reads++;
    return reading;
  }

  @override
  Future<void> stopProcess(int pid) async => stopped.add(pid);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An older server: `terminals.running` is a request it has never heard of.
class _OldTerminals extends _Terminals {
  _OldTerminals() : super(_reading);

  @override
  Future<RunningReading> running() async {
    reads++;
    throw const TerminalRefused(
      'no data request is called "terminals.running"',
    );
  }

  @override
  Future<ListeningPortsReading> listeningPorts() async => ListeningPortsReading(
    ports: const [
      ListeningPort(
        port: 5173,
        address: '::1',
        pid: 11,
        paneId: 'p1',
        terminalSessionId: 'karmashala_s1',
        title: 'Fix the build',
        process: 'node.exe',
      ),
    ],
    checkedAt: DateTime.utc(2026, 10, 6),
  );
}

class _Browser extends BrowserPaneController {
  final navigated = <String>[];

  @override
  BrowserPaneState build() => const BrowserPaneState();

  @override
  Future<void> navigate(String url) async => navigated.add(url);
}

class _Environments extends EnvironmentsController {
  @override
  List<ExecutionEnvironment> build() => [_local, _wsl];
}

class _Routes implements PhoneShellRoutes {
  @override
  void showInbox() {}
  @override
  void showMore(PhoneMoreEntry entry) {}
  @override
  void showProjects() {}
  @override
  void showWorkbench() {}
}

final _local = ExecutionEnvironment(
  id: 'windows',
  createdAt: DateTime.utc(2026),
  name: 'Windows',
  kind: EnvironmentKind.windowsNative,
);
final _wsl = ExecutionEnvironment(
  id: 'wsl:Ubuntu',
  createdAt: DateTime.utc(2026),
  name: 'Ubuntu',
  kind: EnvironmentKind.wsl,
  wslDistribution: 'Ubuntu',
);

final _reading = RunningReading(
  serverPid: 1,
  checkedAt: DateTime.utc(2026, 10, 6),
  processes: const [
    RunningProcess(
      pid: 1,
      parent: 0,
      name: 'karmashala_host.exe',
      role: RunningRole.server,
      ports: [
        RunningPort(port: 47821, address: '127.0.0.1', label: 'MCP endpoint'),
      ],
    ),
    RunningProcess(
      pid: 10,
      parent: 1,
      name: 'pwsh.exe',
      role: RunningRole.pane,
      paneId: 'p1',
      title: 'Fix the build',
      agentSessionId: 's1',
      command: 'npx vite',
    ),
    RunningProcess(
      pid: 11,
      parent: 10,
      name: 'node.exe',
      role: RunningRole.child,
      paneId: 'p1',
      title: 'Fix the build',
      agentSessionId: 's1',
      command: 'npx vite',
      stoppable: true,
      ports: [RunningPort(port: 5173, address: '::1')],
    ),
    RunningProcess(
      pid: 12,
      parent: 10,
      name: 'postgres.exe',
      role: RunningRole.child,
      paneId: 'p1',
      title: 'Fix the build',
      agentSessionId: 's1',
      stoppable: true,
      ports: [RunningPort(port: 5432, address: '127.0.0.1')],
    ),
    RunningProcess(
      pid: 30,
      parent: 1,
      name: 'wsl.exe',
      role: RunningRole.pane,
      paneId: 'p2',
      title: 'ubuntu',
      environmentId: 'wsl:Ubuntu',
    ),
  ],
);

void main() {
  late _Terminals terminals;
  late _Browser browser;
  late List<String> opened;
  late PhoneShellRouter phone;
  String? copied;

  setUp(() {
    terminals = _Terminals(_reading);
    browser = _Browser();
    opened = [];
    phone = PhoneShellRouter();
    copied = null;
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    _Terminals? using,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    final container = ProviderContainer(
      overrides: [
        terminalsClientProvider.overrideWithValue(using ?? terminals),
        browserPaneControllerProvider.overrideWith(() => browser),
        environmentsControllerProvider.overrideWith(_Environments.new),
        localEnvironmentProvider.overrideWithValue(_local),
        portFactsProvider.overrideWithValue(const PortFacts()),
        sessionBackgroundRunsProvider.overrideWith((ref, _) => const []),
        openExternalUrlProvider.overrideWithValue((url) async {
          opened.add(url);
          return true;
        }),
        phoneShellRouterProvider.overrideWithValue(phone),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: RunningTabView())),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('each machine has its own section, this one first', (
    tester,
  ) async {
    await pump(tester);
    final here = find.byKey(const ValueKey('running-machine-windows'));
    final wsl = find.byKey(const ValueKey('running-machine-wsl:Ubuntu'));
    expect(here, findsOneWidget);
    expect(wsl, findsOneWidget);
    expect(tester.getTopLeft(here).dy, lessThan(tester.getTopLeft(wsl).dy));
    expect(
      find.descendant(of: wsl, matching: find.textContaining('wsl.exe')),
      findsOneWidget,
    );
    // A port is named by what holds it, never by asking it.
    expect(find.text(':5173 — Vite dev server'), findsOneWidget);
    expect(find.text(':5432 — PostgreSQL'), findsOneWidget);
    expect(find.text(':47821 — MCP endpoint'), findsOneWidget);
  });

  testWidgets('one machine can be picked', (tester) async {
    final container = await pump(tester);
    container.read(runningFilterProvider.notifier).machine('wsl:Ubuntu');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('running-machine-windows')), findsNothing);
    expect(
      find.byKey(const ValueKey('running-machine-wsl:Ubuntu')),
      findsOneWidget,
    );
  });

  testWidgets('an http port opens in the Browser pane, in the system browser, '
      'or is copied; a database is only copied', (tester) async {
    final container = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('running-open-5173')));
    await tester.pumpAndSettle();
    expect(browser.navigated, ['http://localhost:5173']);
    expect(container.read(sidePanelProvider), SidePanelSurface.browser);

    await tester.tap(find.byKey(const ValueKey('running-system-browser-5173')));
    expect(opened, ['http://localhost:5173']);

    await tester.tap(find.byKey(const ValueKey('running-copy-5173')));
    expect(copied, 'http://localhost:5173');

    expect(find.byKey(const ValueKey('running-open-5432')), findsNothing);
    expect(
      find.byKey(const ValueKey('running-system-browser-5432')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('running-copy-5432')));
    expect(copied, 'localhost:5432');
  });

  testWidgets('Stop asks first, naming the process and its owner; the server '
      'and a pane\'s root offer no Stop', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('running-stop-1')), findsNothing);
    expect(find.byKey(const ValueKey('running-stop-10')), findsNothing);
    expect(
      find.byKey(const ValueKey('running-server-settings')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('running-stop-11')));
    await tester.pumpAndSettle();
    expect(find.text('Stop node.exe?'), findsOneWidget);
    expect(find.textContaining('"Fix the build"'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(terminals.stopped, isEmpty);

    await tester.tap(find.byKey(const ValueKey('running-stop-11')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('running-stop-confirm')));
    await tester.pumpAndSettle();
    expect(terminals.stopped, [11]);
  });

  testWidgets('it reads while open, on Refresh, and never once closed', (
    tester,
  ) async {
    final container = await pump(tester);
    expect(terminals.reads, 1);
    await tester.pump(RunningTabView.refreshInterval);
    await tester.pumpAndSettle();
    expect(terminals.reads, 2);
    await tester.tap(find.byKey(const ValueKey('running-refresh')));
    await tester.pumpAndSettle();
    expect(terminals.reads, 3);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox()),
      ),
    );
    await tester.pump(RunningTabView.refreshInterval * 5);
    expect(terminals.reads, 3);
  });

  testWidgets('an older server still lists its panes\' ports, and offers no '
      'Stop', (tester) async {
    final old = _OldTerminals();
    await pump(tester, using: old);
    expect(find.text(':5173 — Node server'), findsOneWidget);
    expect(find.byKey(const ValueKey('running-stop-11')), findsNothing);
    expect(find.textContaining('older than this app'), findsOneWidget);
  });

  testWidgets('on a phone, Open asks the server to show it on the desktop', (
    tester,
  ) async {
    phone.attach(_Routes());
    final container = await pump(tester, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('running-system-browser-5173')),
      findsNothing,
      reason: 'the phone\'s own browser would reach the phone',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('running-open-5173')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('running-open-5173')));
    await tester.pumpAndSettle();
    expect(browser.navigated, ['http://localhost:5173']);
    expect(container.read(sidePanelProvider), isNull);
    expect(find.textContaining('desktop\'s Browser'), findsOneWidget);
  });
}

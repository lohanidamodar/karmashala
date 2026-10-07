import 'package:agent_cli/descriptors.dart' show AgentRegistry;
import 'package:agent_cli/process.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_routes.dart';
import 'package:karmashala/src/app/shell/running_tab_view.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/browser/application/browser_pane_controller.dart';
import 'package:karmashala/src/features/environments/application/environment_providers.dart';
import 'package:karmashala/src/features/environments/application/environments_controller.dart';
import 'package:karmashala/src/features/git/application/remote_links.dart';
import 'package:karmashala/src/features/running/application/running_providers.dart';
import 'package:karmashala/src/features/running/domain/port_label.dart';
import 'package:karmashala/src/features/sessions/application/background_runs_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_agent_providers.dart';
import 'package:karmashala/src/features/terminal/data/terminals_client.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'running_fixture.dart';

/// The server's terminals, answering the Running tab's two requests only.
class _Terminals implements TerminalsClient {
  _Terminals(this.reading);

  RunningReading reading;
  int reads = 0;
  final stopped = <(int, String?)>[];

  @override
  Future<RunningReading> running() async {
    reads++;
    return reading;
  }

  @override
  Future<void> stopProcess(int pid, {String? machine}) async =>
      stopped.add((pid, machine));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An older server: `terminals.running` is a request it has never heard of.
class _OldTerminals extends _Terminals {
  _OldTerminals() : super(runningFixture);

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
  List<ExecutionEnvironment> build() => [fixtureLocal, fixtureWsl, fixtureBox];
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

void main() {
  late _Terminals terminals;
  late _Browser browser;
  late List<String> opened;
  late PhoneShellRouter phone;
  String? copied;

  setUp(() {
    terminals = _Terminals(runningFixture);
    browser = _Browser();
    opened = [];
    phone = PhoneShellRouter();
    copied = null;
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1,
    _Terminals? using,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
        localEnvironmentProvider.overrideWithValue(fixtureLocal),
        portFactsProvider.overrideWithValue(const PortFacts()),
        sessionBackgroundRunsProvider.overrideWith((ref, _) => const []),
        sessionAgentIdProvider.overrideWith((ref, _) => 'claudeCode'),
        agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
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

  Finder inCard(String key, Finder matching) => find.descendant(
    of: find.byKey(ValueKey('running-card-$key')),
    matching: matching,
  );

  testWidgets('ports come first, left of the sessions on a desktop; a WSL '
      'session\'s port 3000 is a link under that session', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    final listening = tester.getTopLeft(
      find.byKey(const ValueKey('running-heading-listening')),
    );
    final sessions = tester.getTopLeft(
      find.byKey(const ValueKey('running-heading-sessions')),
    );
    expect(listening.dx, lessThan(sessions.dx));
    expect((listening.dy - sessions.dy).abs(), lessThan(1));

    expect(find.byKey(const ValueKey('running-link-3000')), findsOneWidget);
    expect(find.text('localhost:3000'), findsOneWidget);
    expect(find.textContaining('Vite dev server'), findsOneWidget);
    expect(
      inCard('pa', find.textContaining(':3000')),
      findsOneWidget,
      reason: 'the analytics card names its port',
    );
    expect(
      inCard('pa', find.textContaining('WSL · archlinux')),
      findsOneWidget,
    );
    // A database is not a link: its address is text to copy.
    expect(find.byKey(const ValueKey('running-link-5432')), findsNothing);
    expect(find.byKey(const ValueKey('running-address-5432')), findsOneWidget);
  });

  testWidgets('one click on a link opens the system browser at once and not '
      'the pane; the small globe and Ctrl-click open the pane; Copy copies', (
    tester,
  ) async {
    final container = await pump(tester);
    final link = find.byKey(const ValueKey('running-link-3000'));
    expect(tester.getSize(link).height, greaterThanOrEqualTo(32));
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(opened, ['http://localhost:3000']);
    expect(browser.navigated, isEmpty);
    expect(container.read(sidePanelProvider), isNull);
    expect(find.byType(PopupMenuItem<Object?>), findsNothing);

    await tester.tap(find.byKey(const ValueKey('running-open-pane-3000')));
    await tester.pumpAndSettle();
    expect(browser.navigated, ['http://localhost:3000']);
    expect(container.read(sidePanelProvider), SidePanelSurface.browser);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(link);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(browser.navigated, hasLength(2));
    expect(opened, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('running-copy-3000')));
    expect(copied, 'http://localhost:3000');
    await tester.tap(find.byKey(const ValueKey('running-copy-5432')));
    expect(copied, 'localhost:5432');
  });

  testWidgets('a port on an SSH box is host:port, copied, and never opened '
      'as this machine\'s localhost', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('running-link-8080')), findsNothing);
    expect(find.byKey(const ValueKey('running-open-pane-8080')), findsNothing);
    expect(find.text('box.example:8080'), findsOneWidget);
    expect(find.textContaining('not forwarded here'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('running-copy-8080')));
    expect(copied, 'box.example:8080');
  });

  testWidgets('wrappers hide behind a count and duplicates are one group', (
    tester,
  ) async {
    await pump(tester);
    expect(
      inCard('pn', find.textContaining('flutter_tester.exe')),
      findsOneWidget,
    );
    expect(inCard('pn', find.textContaining('×6')), findsOneWidget);
    expect(inCard('pn', find.textContaining('conhost.exe')), findsNothing);
    final helpers = find.byKey(const ValueKey('running-helpers-pn'));
    expect(
      find.descendant(of: helpers, matching: find.text('7 helper processes')),
      findsOneWidget,
    );
    await tester.tap(helpers);
    await tester.pumpAndSettle();
    expect(inCard('pn', find.textContaining('conhost.exe')), findsNWidgets(6));

    await tester.tap(find.byKey(const ValueKey('running-all-pn')));
    await tester.pumpAndSettle();
    expect(inCard('pn', find.textContaining('pid 31184')), findsOneWidget);
  });

  testWidgets('the server\'s ports are one quiet card that opens to them', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Karmashala server · 4 ports'), findsOneWidget);
    expect(find.textContaining('MCP endpoint'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('running-server-toggle')));
    await tester.pumpAndSettle();
    expect(find.textContaining('MCP endpoint'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('running-server-settings')),
      findsOneWidget,
    );
  });

  testWidgets('Stop is behind ⋯, asks first, and names the machine a WSL '
      'process is on; the server and a pane\'s root offer none', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('running-more-38080')), findsNothing);
    expect(find.byKey(const ValueKey('running-more-42376')), findsNothing);
    expect(find.text('Stop'), findsNothing, reason: 'not on every row');

    // The vite port's card: its ⋯ shows when the pointer is over it.
    final card = find.byKey(
      const ValueKey('running-port-wsl:archlinux-421-3000'),
    );
    final more = find.descendant(
      of: card,
      matching: find.byKey(const ValueKey('running-more-421')),
    );
    expect(
      find.descendant(of: more, matching: find.byType(PopupMenuButton<String>)),
      findsNothing,
      reason: 'hidden until hovered',
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(card));
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('running-stop-421')));
    await tester.pumpAndSettle();
    expect(find.text('Stop node?'), findsOneWidget);
    expect(find.textContaining('"analytics"'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(terminals.stopped, isEmpty);

    // A right-click on the row is the same menu.
    await tester.tap(card, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('running-stop-421')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('running-stop-confirm')));
    await tester.pumpAndSettle();
    expect(terminals.stopped, [(421, 'wsl:archlinux')]);
  });

  testWidgets('a note about a session sits on its card and can be put away', (
    tester,
  ) async {
    terminals.reading = RunningReading(
      serverPid: runningFixture.serverPid,
      checkedAt: runningFixture.checkedAt,
      processes: runningFixture.processes,
      notes: const [
        RunningNote(
          '"deploy api" runs on an SSH machine with no connection open; its '
          'processes are not read.',
          environmentId: 'ssh:box',
        ),
      ],
    );
    await pump(tester);
    final note = inCard('pd', find.textContaining('no connection open'));
    expect(note, findsOneWidget);
    await tester.tap(inCard('pd', find.byTooltip('Dismiss')));
    await tester.pumpAndSettle();
    expect(note, findsNothing);
  });

  testWidgets('the filter box keeps the ports and processes that match', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('running-search')),
        matching: find.byType(EditableText),
      ),
      'vite',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('running-link-3000')), findsOneWidget);
    expect(find.byKey(const ValueKey('running-address-5432')), findsNothing);
    expect(find.byKey(const ValueKey('running-card-pn')), findsNothing);
  });

  testWidgets('one machine can be picked', (tester) async {
    final container = await pump(tester);
    container.read(runningFilterProvider.notifier).machine('wsl:archlinux');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('running-card-pn')), findsNothing);
    expect(find.byKey(const ValueKey('running-card-pa')), findsOneWidget);
    expect(find.text('Karmashala server · 4 ports'), findsNothing);
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
    expect(find.textContaining('Node server'), findsOneWidget);
    expect(find.byKey(const ValueKey('running-more-11')), findsNothing);
    expect(find.textContaining('older than this app'), findsOneWidget);
  });

  testWidgets('on a phone: one column, sessions folded, and Open asks the '
      'server to show it on the desktop', (tester) async {
    phone.attach(_Routes());
    final container = await pump(tester, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('running-link-3000'))).height,
      greaterThanOrEqualTo(44),
    );
    expect(
      find.byKey(const ValueKey('running-open-pane-3000')),
      findsNothing,
      reason: 'the phone\'s own browser would reach the phone',
    );
    await tester.tap(find.byKey(const ValueKey('running-link-3000')));
    await tester.pumpAndSettle();
    expect(browser.navigated, ['http://localhost:3000']);
    expect(opened, isEmpty);
    expect(container.read(sidePanelProvider), isNull);
    expect(find.textContaining('desktop\'s Browser'), findsOneWidget);

    final listening = tester.getTopLeft(
      find.byKey(const ValueKey('running-heading-listening')),
    );
    await scrollTo(tester, const ValueKey('running-heading-sessions'));
    final sessions = tester.getTopLeft(
      find.byKey(const ValueKey('running-heading-sessions')),
    );
    expect(sessions.dx, listening.dx, reason: 'one column');
    await scrollTo(tester, const ValueKey('running-session-pn'));
    expect(find.byKey(const ValueKey('running-all-pn')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('running-session-pn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('running-all-pn')), findsOneWidget);
  });

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('at 1.6× text on a $name nothing overflows', (tester) async {
      // An overflow fails the test by itself, naming the row.
      await pump(tester, size: size, textScale: 1.6);
      await scrollTo(tester, const ValueKey('running-session-pn'));
      await tester.tap(find.byKey(const ValueKey('running-session-pn')));
      await tester.pumpAndSettle();
      await scrollTo(tester, const ValueKey('running-card-pd'));
    });
  }
}

/// Scrolls the tab until [key] is built and on screen.
Future<void> scrollTo(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(
    find.byKey(key),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

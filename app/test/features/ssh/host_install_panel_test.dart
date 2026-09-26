import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/application/ssh_relays.dart';
import 'package:karmashala/src/features/ssh/application/host_install_controller.dart';
import 'package:karmashala/src/features/ssh/application/ssh_terminal_opener.dart';
import 'package:karmashala/src/features/ssh/presentation/host_install_panel.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';
import 'fake_host_box.dart';
import '../../support/test_machine.dart';

class _Access extends RemoteAccessController {
  _Access(super.ref);

  @override
  Future<void> sync() async {}
}

void main() {
  late TestMachine db;
  late FakeDataServer server;
  late DataClient data;
  late FakeHostBox box;
  late List<({String host, String? typed})> terminals;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer(clock: () => testTime);
    data = await server.connect();
    box = FakeHostBox();
    terminals = [];
  });

  ProviderContainer containerFor({
    FakeBundles? bundles,
    bool realTerminals = false,
  }) {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        dataClientProvider.overrideWithValue(data),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        remoteAccessControllerProvider.overrideWith(_Access.new),
        hostInstallerFactoryProvider.overrideWithValue(
          (host) => installerOver(box, bundles: bundles),
        ),
        if (!realTerminals)
          sshTerminalOpenerProvider.overrideWithValue((host, {typed}) {
            terminals.add((host: host.name, typed: typed));
            return true;
          }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Widget panel(ProviderContainer container, {bool debugRun = false}) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: HostInstallPanel(host: boxHost, debugRun: debugRun),
              ),
            ),
          ),
        ),
      );

  Future<void> settle(WidgetTester tester) => settleHostBox(tester);

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    FakeBundles? bundles,
    bool debugRun = false,
    bool realTerminals = false,
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = containerFor(
      bundles: bundles,
      realTerminals: realTerminals,
    );
    await tester.pumpWidget(panel(container, debugRun: debugRun));
    return container;
  }

  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await settle(tester);
  }

  testWidgets('nothing is claimed before somebody asks, and nothing is asked '
      'on its own', (tester) async {
    await pump(tester);
    await settle(tester);

    expect(
      find.text('Karmashala host: not checked since this launch'),
      findsOneWidget,
    );
    expect(
      box.commands,
      isEmpty,
      reason: 'a reading is asked for, never polled',
    );
  });

  testWidgets('not installed → Install → installed and running, under the '
      'home and with no sudo', (tester) async {
    await pump(tester);

    await press(tester, 'Check');
    expect(find.text('Karmashala host: not installed'), findsOneWidget);
    expect(find.textContaining('no root needed'), findsOneWidget);
    expect(find.textContaining('Checked 3m ago'), findsOneWidget);
    expect(box.uploads, isEmpty);

    await press(tester, 'Install');

    expect(
      find.text('Karmashala host: installed 1.25.0 (running)'),
      findsOneWidget,
    );
    expect(
      box.uploads.single,
      '$kBoxBin/karmashala_host-1.25.0-linux-x64.tar.gz',
    );
    expect(
      box.commands.any(
        (c) =>
            c.contains("setsid nohup '${boxExecutable(kBoxThisBundle)}' serve"),
      ),
      isTrue,
    );
    expect(box.commands.any((c) => c.contains('sudo')), isFalse);
    expect(find.text('Reinstall'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Uninstall'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
  });

  testWidgets('while the machine is being asked the row says what for, and '
      'its buttons wait', (tester) async {
    await pump(tester);
    box.gate = Completer<void>();

    await tester.tap(find.text('Check'));
    await tester.pump();

    expect(find.byType(InlineSpinner), findsOneWidget);
    expect(find.text('Asking the machine…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Check'))
          .onPressed,
      isNull,
    );

    box.gate!.complete();
    box.gate = null;
    await settle(tester);
    expect(find.byType(InlineSpinner), findsNothing);
  });

  testWidgets('an older host reads "older than this app" and offers Update', (
    tester,
  ) async {
    box
      ..installed.add(kBoxOlderBundle)
      ..runningServe = boxExecutable(kBoxOlderBundle);
    await pump(tester);

    await press(tester, 'Check');
    expect(
      find.text(
        'Karmashala host: older than this app (1.24.0 → 1.25.0), running',
      ),
      findsOneWidget,
    );

    await press(tester, 'Update');
    expect(
      find.text('Karmashala host: installed 1.25.0 (running)'),
      findsOneWidget,
    );
    expect(box.runningServe, boxExecutable(kBoxThisBundle));
  });

  testWidgets('a host newer than this app is said to be newer, and going back '
      'is not called Update', (tester) async {
    const newer = 'karmashala_host-1.26.0-linux-x64.d';
    box
      ..installed.add(newer)
      ..runningServe = boxExecutable(newer);
    await pump(tester);

    await press(tester, 'Check');

    expect(
      find.text(
        'Karmashala host: newer than this app (1.26.0; this app carries '
        '1.25.0), running',
      ),
      findsOneWidget,
    );
    expect(find.text('Update'), findsNothing);
    expect(find.text('Install 1.25.0'), findsOneWidget);
  });

  testWidgets('Stop asks first when the host holds work, and Start brings it '
      'back', (tester) async {
    box
      ..installed.add(kBoxThisBundle)
      ..runningServe = boxExecutable(kBoxThisBundle)
      ..heldSessions = 2;
    await pump(tester);
    await press(tester, 'Check');

    await press(tester, 'Stop');
    expect(
      find.textContaining('The 2 sessions it holds end with it'),
      findsOneWidget,
    );
    expect(box.runningServe, isNotNull, reason: 'nothing before the answer');

    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await settle(tester);
    expect(
      find.text('Karmashala host: installed 1.25.0 (stopped)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('2 session(s) it held have ended'),
      findsOneWidget,
    );

    await press(tester, 'Start');
    expect(
      find.text('Karmashala host: installed 1.25.0 (running)'),
      findsOneWidget,
    );
    expect(find.textContaining('does not come back by itself'), findsOneWidget);
  });

  testWidgets('Uninstall says what goes and what stays, then does it — and the '
      'relay row here goes with it', (tester) async {
    box
      ..installed.add(kBoxThisBundle)
      ..runningServe = boxExecutable(kBoxThisBundle);
    server.writeAsAnotherClient([
      const PreferenceChanged(
        kSshRelaysMetadataKey,
        '[{"hostId":"h1","hostName":"do-box","port":8787,'
        '"url":"ws://203.0.113.9:8787/k/0123456789abcdef0123456789abcdef",'
        '"enabled":true}]',
      ),
    ]);
    final container = await pump(tester);
    await press(tester, 'Check');

    await press(tester, 'Uninstall');
    expect(find.textContaining('~/.karmashala/bin is deleted'), findsOneWidget);
    expect(
      find.textContaining('Left in place: ~/.karmashala/sessions'),
      findsOneWidget,
    );
    expect(
      box.commands.where((c) => c.contains('karmashala-removed')),
      isEmpty,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Uninstall'));
    await settle(tester);

    expect(find.text('Karmashala host: not installed'), findsOneWidget);
    expect(find.textContaining('Left in place'), findsOneWidget);
    expect(box.runningServe, isNull);
    expect(
      box.commands.singleWhere((c) => c.contains('karmashala-removed')),
      contains("rm -rf '$kBoxBin'/karmashala_host-*"),
    );
    expect(container.read(sshRelaysProvider), isEmpty);
  });

  testWidgets('a build with no bundle for the machine says what the machine '
      'is, what the build carries, and the remedy', (tester) async {
    box.uname = 'Linux\naarch64\nldd (GNU libc) 2.36\n';
    await pump(tester);

    await press(tester, 'Check');

    expect(find.text('Karmashala host: can\'t install'), findsOneWidget);
    expect(find.textContaining('linux/arm64 (glibc)'), findsOneWidget);
    expect(find.textContaining('it carries linux-x64 only'), findsOneWidget);
    expect(
      find.textContaining('ships the linux-arm64 host bundle'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('dart build cli'), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
  });

  testWidgets('the 2026-09-17 app — no bundles at all — on a debug run gets '
      'the build command', (tester) async {
    await pump(tester, bundles: FakeBundles(const []), debugRun: true);

    await press(tester, 'Check');

    expect(find.textContaining('it carries none at all'), findsOneWidget);
    expect(find.textContaining('dart build cli'), findsOneWidget);
    expect(find.textContaining('--target-arch=x64'), findsOneWidget);
  });

  group('a step that needs sudo', () {
    const command = 'sudo apt-get install -y tar';

    Future<ProviderContainer> missingTar(
      WidgetTester tester, {
      bool realTerminals = false,
    }) async {
      box.tools = 'missing=tar\npm=apt-get\nuid=1000\n';
      final container = await pump(tester, realTerminals: realTerminals);
      await press(tester, 'Check');
      await press(tester, 'Install');
      return container;
    }

    testWidgets('shows the command, what it does and why — and never runs it', (
      tester,
    ) async {
      await missingTar(tester);

      expect(find.text(command), findsOneWidget);
      expect(find.textContaining('Installs tar on'), findsOneWidget);
      expect(
        find.textContaining('yours to run, in a terminal there'),
        findsOneWidget,
      );
      expect(find.text('Open a terminal on do-box'), findsOneWidget);
      expect(box.uploads, isEmpty);
      expect(box.commands.any((c) => c.contains('apt-get install')), isFalse);
    });

    testWidgets('"Open a terminal" types the command there and does not press '
        'Enter', (tester) async {
      await missingTar(tester);

      await press(tester, 'Open a terminal on do-box');

      expect(terminals, [(host: 'do-box', typed: command)]);
      expect(
        terminals.single.typed,
        isNot(anyOf(contains('\n'), contains('\r'))),
      );
      expect(find.textContaining('not run: press Enter there'), findsOneWidget);
    });

    testWidgets('the real opener opens an SSH tab on that host with the text '
        'handed to the pane, unsubmitted', (tester) async {
      final container = await missingTar(tester, realTerminals: true);

      await press(tester, 'Open a terminal on do-box');

      final state = container.read(terminalSessionsControllerProvider);
      final paneId = state.activeTab!.focusedPaneId;
      final pane =
          container
                  .read(terminalSessionsControllerProvider.notifier)
                  .instanceFor(paneId)!
              as FakeTerminalInstance;
      expect(pane.profileId, 'ssh:h1');
      expect(pane.typedAtPrompt, [command]);
      expect(pane.typedAtPrompt.single.endsWith('\n'), isFalse);
      expect(pane.typedAtPrompt.single.endsWith('\r'), isFalse);
    });

    testWidgets(
      '"Check again" re-reads the machine, and a fixed one installs',
      (tester) async {
        await missingTar(tester);
        box.tools = 'uid=1000\n';

        await press(tester, 'Check again');

        expect(
          find.text('Karmashala host: installed 1.25.0 (running)'),
          findsOneWidget,
        );
        expect(find.text(command), findsNothing);
      },
    );
  });

  testWidgets('survives the window matrix at its wordiest', (tester) async {
    box.tools = 'missing=tar\npm=apt-get\nuid=1000\n';
    await expectSurvivesWindowMatrix(
      tester,
      build: () => panel(containerFor()),
      warmUp: (tester) async {
        await tester.tap(find.text('Check'));
        await settle(tester);
        await tester.tap(find.text('Install'));
        await settle(tester);
      },
      because: 'a sentence, a remedy, a command and five buttons in one card',
    );
  });
}

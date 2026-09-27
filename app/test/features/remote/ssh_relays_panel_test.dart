import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/application/ssh_relay_controller.dart';
import 'package:karmashala/src/features/remote/application/ssh_relays.dart';
import 'package:karmashala/src/features/remote/presentation/ssh_relays_panel.dart';
import 'package:karmashala/src/features/ssh/application/host_install_controller.dart';
import 'package:karmashala/src/features/ssh/application/ssh_terminal_opener.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh_host/host.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../ssh/fake_host_box.dart';

const _token = '0123456789abcdef0123456789abcdef';
final _url = Uri.parse('ws://203.0.113.9:8787/k/$_token');

class _Access extends RemoteAccessController {
  _Access(super.ref);

  @override
  Future<void> sync() async {}
}

class _Setup implements SshRelaySetup {
  _Setup(this.answers);

  final Map<String, SshRelayReading> answers;
  final asked = <String>[];

  /// Whether each `start` was a check after the firewall command was run.
  final byHand = <bool>[];

  Future<SshRelayReading> _answer(String action) async {
    asked.add(action);
    return answers[action]!;
  }

  @override
  Future<SshRelayReading> start({bool ruleAddedByHand = false}) {
    byHand.add(ruleAddedByHand);
    // A second answer, when a test gives one, is what checking again finds.
    final again = answers['start again'];
    return _answer(ruleAddedByHand && again != null ? 'start again' : 'start');
  }

  @override
  Future<SshRelayReading> check() => _answer('check');
  @override
  Future<SshRelayReading> stop() => _answer('stop');
  @override
  Future<SshRelayReading> remove() => _answer('remove');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SshRelayReading _reading(
  SshRelayStatus status, {
  String? reason,
  String? command,
  PrivilegedCommand? privileged,
  bool outside = false,
  bool withUrl = true,
}) => SshRelayReading(
  status: status,
  observedAt: testTime.subtract(const Duration(minutes: 3)),
  reason: reason ?? 'The relay on do-box answered on port 8787.',
  command: command ?? privileged?.command,
  privileged: privileged,
  outsideTheMachine: outside,
  port: 8787,
  url: withUrl ? _url : null,
);

void main() {
  late FakeDataServer server;

  setUp(() {
    server = FakeDataServer(clock: () => testTime);
  });

  void addHost() => server.sshHostRows.upsert(
    SshHost(
      id: 'h1',
      name: 'do-box',
      host: '203.0.113.9',
      port: 22,
      username: 'dlohani',
      authMethod: SshAuthMethod.password,
      createdAt: testTime,
    ),
  );

  void addRelay({bool enabled = true}) => server.store.write(
    kSshRelaysMetadataKey,
    '[{"hostId":"h1","hostName":"do-box","port":8787,"url":"$_url",'
    '"enabled":$enabled}]',
  );

  final terminals = <({String host, String? typed})>[];
  setUp(terminals.clear);

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    _Setup? setup,
    List<int>? ports,
    SshRelaySetupFactory? factory,
    FakeHostBox? box,
  }) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final data = await server.override();
    final container = ProviderContainer(
      overrides: [
        data,
        clockProvider.overrideWithValue(FixedClock(testTime)),
        remoteAccessControllerProvider.overrideWith(_Access.new),
        sshRelaySetupFactoryProvider.overrideWithValue(
          factory ??
              (host, port) async {
                ports?.add(port);
                return setup ?? (throw StateError('no box in this test'));
              },
        ),
        sshTerminalOpenerProvider.overrideWithValue((host, {typed}) {
          terminals.add((host: host.name, typed: typed));
          return true;
        }),
        if (box != null)
          hostInstallerFactoryProvider.overrideWithValue(
            (host) => installerOver(box),
          ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: SshRelaysPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  Finder useButton() =>
      find.widgetWithText(OutlinedButton, 'Use an SSH host as a relay…');

  testWidgets('with no SSH host there is nothing to use, and it says where '
      'to add one', (tester) async {
    await pump(tester);

    expect(tester.widget<OutlinedButton>(useButton()).onPressed, isNull);
    expect(find.textContaining('Settings → Environments'), findsOneWidget);
  });

  testWidgets('setting one up: pick, port, prove — and the row appears', (
    tester,
  ) async {
    addHost();
    final ports = <int>[];
    final setup = _Setup({'start': _reading(SshRelayStatus.running)});
    final container = await pump(tester, setup: setup, ports: ports);

    await tester.tap(useButton());
    await tester.pumpAndSettle();
    expect(find.text('Use an SSH host as a relay'), findsOneWidget);
    // Said before anything happens: what it can see, and that it is not TLS.
    expect(find.textContaining('can read none of them'), findsOneWidget);
    expect(find.textContaining('is not TLS'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Relay port'),
      '9100',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Set up'));
    await tester.pumpAndSettle();

    expect(ports, [9100]);
    expect(setup.asked, ['start']);
    expect(find.textContaining('answered on port 8787'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await tester.pumpAndSettle();

    expect(container.read(activeSshRelayUrlsProvider), [_url]);
    expect(find.text('ws://203.0.113.9:8787'), findsOneWidget);
    expect(find.textContaining(_token), findsNothing);
    expect(find.textContaining('/k/'), findsNothing);
  });

  testWidgets('a port that cannot be one is refused before the machine is '
      'touched', (tester) async {
    addHost();
    final setup = _Setup({'start': _reading(SshRelayStatus.running)});
    await pump(tester, setup: setup);
    await tester.tap(useButton());
    await tester.pumpAndSettle();

    for (final (typed, complaint) in [
      ('http', 'a number from 1 to 65535'),
      ('70000', 'a number from 1 to 65535'),
      ('22', 'the port SSH itself answers on'),
    ]) {
      await tester.enterText(
        find.widgetWithText(TextField, 'Relay port'),
        typed,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Set up'));
      await tester.pumpAndSettle();
      expect(find.textContaining(complaint), findsOneWidget, reason: typed);
    }
    expect(setup.asked, isEmpty);
  });

  testWidgets('a relay that runs but is shut from here says what to run', (
    tester,
  ) async {
    addHost();
    final setup = _Setup({
      'start': _reading(
        SshRelayStatus.unreachable,
        reason:
            'The relay is running on do-box. A firewall is running on '
            '203.0.113.9 and this cannot change it without a password.',
        command: 'sudo ufw allow 8787/tcp',
      ),
    });
    final container = await pump(tester, setup: setup);
    await tester.tap(useButton());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Set up'));
    await tester.pumpAndSettle();

    expect(find.text('sudo ufw allow 8787/tcp'), findsWidgets);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
    expect(container.read(activeSshRelayUrlsProvider), isEmpty);
  });

  group('a box the session host could not be put on', () {
    HostDeployment noBundle() => HostDeployment(
      status: HostDeploymentStatus.noBinary,
      observedAt: testTime.subtract(const Duration(minutes: 1)),
      reason: 'No host binary for linux-x64 in this build.',
      platform: HostPlatform(
        operatingSystem: 'linux',
        architecture: 'x64',
        libc: HostLibc.glibc,
        observedAt: testTime,
      ),
    );

    testWidgets('reads as a sentence, a remedy and a button — the 2026-09-17 '
        '"Bad state:" is gone', (tester) async {
      addHost();
      await pump(
        tester,
        factory: (host, port) async => throw HostDeployFailure(
          hostName: host.name,
          deployment: noBundle(),
        ),
      );
      await tester.tap(useButton());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Set up'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Bad state'), findsNothing);
      expect(find.textContaining('could not be put on'), findsNothing);
      // What the box is, what this build carries, and what to do about it.
      expect(find.textContaining('linux/x64 (glibc)'), findsOneWidget);
      expect(find.textContaining('it carries none at all'), findsOneWidget);
      expect(
        find.textContaining('ships the linux-x64 host bundle'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    });

    testWidgets('its button installs, and the relay is then set up without '
        'being asked twice', (tester) async {
      addHost();
      final box = FakeHostBox();
      final setup = _Setup({'start': _reading(SshRelayStatus.running)});
      var deployed = false;
      await pump(
        tester,
        box: box,
        factory: (host, port) async {
          if (!deployed && box.installed.isEmpty) {
            throw HostDeployFailure(
              hostName: host.name,
              deployment: HostDeployment(
                status: HostDeploymentStatus.cannotInstall,
                observedAt: testTime.subtract(const Duration(minutes: 1)),
                reason: 'Could not write the bundle on do-box.',
              ),
            );
          }
          deployed = true;
          return setup;
        },
      );
      await tester.tap(useButton());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Set up'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not write the bundle'), findsOneWidget);
      expect(find.textContaining('no root is needed'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Install'));
      await settleHostBox(tester);

      expect(box.uploads, hasLength(1));
      expect(setup.asked, ['start']);
      expect(find.textContaining('answered on port 8787'), findsWidgets);
    });
  });

  group('a firewall that wants a password', () {
    const command = 'sudo ufw allow 8787/tcp';
    final needsSudo = _reading(
      SshRelayStatus.unreachable,
      reason:
          'The relay is running on do-box. ufw is running on 203.0.113.9 and '
          '`sudo` there asks for a password, so 8787/tcp was not opened.',
      privileged: const PrivilegedCommand(
        command: command,
        does: 'Allows inbound TCP 8787 through ufw on 203.0.113.9.',
        why:
            '`sudo` on 203.0.113.9 asks for a password, and Karmashala never '
            'asks for one.',
      ),
    );

    testWidgets('the dialog shows the command and opens a terminal with it '
        'typed — never the token, never a password field', (tester) async {
      addHost();
      final setup = _Setup({'start': needsSudo});
      await pump(tester, setup: setup);
      await tester.tap(useButton());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Set up'));
      await tester.pumpAndSettle();

      expect(find.text(command), findsWidgets);
      expect(find.textContaining('never asks for one'), findsWidgets);
      expect(find.textContaining(_token), findsNothing);
      expect(find.byType(TextField), findsOneWidget, reason: 'the port, only');

      await tester.tap(find.text('Open a terminal on do-box').last);
      await tester.pumpAndSettle();

      expect(terminals, [(host: 'do-box', typed: command)]);
      expect(terminals.single.typed, isNot(contains(_token)));
      expect(terminals.single.typed!.endsWith('\n'), isFalse);
      // The dialog made way for the terminal; the row carries on from here.
      expect(find.text('Use an SSH host as a relay'), findsNothing);
      expect(find.text('Check again'), findsOneWidget);
    });

    testWidgets('"Check again" re-reads, and a port still shut after the '
        'command is the provider\'s — not more sudo', (tester) async {
      addHost();
      addRelay(enabled: false);
      final setup = _Setup({
        'start': needsSudo,
        'start again': _reading(
          SshRelayStatus.unreachable,
          reason:
              'The relay is running on do-box. 203.0.113.9:8787 still does '
              'not answer. Allow inbound TCP 8787 in the provider\'s console — '
              'DigitalOcean: Networking › Firewalls.',
          outside: true,
        ),
      });
      await pump(tester, setup: setup);
      await tester.tap(find.widgetWithText(TextButton, 'Start'));
      await tester.pumpAndSettle();
      expect(find.text(command), findsOneWidget);

      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();

      expect(setup.byHand, [false, true]);
      expect(find.textContaining('DigitalOcean'), findsOneWidget);
      expect(find.text(command), findsNothing);
      expect(find.text('Open a terminal on do-box'), findsNothing);
    });

    testWidgets('Start after the terminal step is a check again too', (
      tester,
    ) async {
      addHost();
      addRelay(enabled: false);
      final setup = _Setup({'start': needsSudo});
      await pump(tester, setup: setup);
      await tester.tap(find.widgetWithText(TextButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open a terminal on do-box'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Start'));
      await tester.pumpAndSettle();

      expect(setup.byHand, [false, true]);
    });
  });

  testWidgets('a row claims nothing it has not measured this launch', (
    tester,
  ) async {
    addHost();
    addRelay();
    final setup = _Setup({'check': _reading(SshRelayStatus.running)});
    await pump(tester, setup: setup);

    expect(
      find.textContaining('Not checked since this launch'),
      findsOneWidget,
    );
    expect(find.textContaining('answered'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Check'));
    await tester.pumpAndSettle();

    expect(find.textContaining('answered on port 8787'), findsOneWidget);
    // A reading with its age, never a bare verdict (§19).
    expect(find.textContaining('Checked 3m ago'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Stop'), findsOneWidget);
  });

  testWidgets('a relay from an older app version offers Update, and Update '
      'is start', (tester) async {
    addHost();
    addRelay();
    final setup = _Setup({
      'check': _reading(
        SshRelayStatus.outdated,
        reason: 'The relay on do-box is from another version.',
      ),
      'start': _reading(SshRelayStatus.running),
    });
    await pump(tester, setup: setup);
    await tester.tap(find.widgetWithText(TextButton, 'Check'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();

    expect(setup.asked, ['check', 'start']);
    expect(find.widgetWithText(FilledButton, 'Update'), findsNothing);
  });

  testWidgets('a stopped one offers Start, and removing asks first', (
    tester,
  ) async {
    addHost();
    addRelay(enabled: false);
    final setup = _Setup({
      'remove': _reading(SshRelayStatus.stopped, withUrl: false),
    });
    final container = await pump(tester, setup: setup);
    expect(find.widgetWithText(TextButton, 'Start'), findsOneWidget);
    expect(find.textContaining('Not serving through it'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('stops working for good'), findsOneWidget);
    expect(setup.asked, isEmpty, reason: 'nothing happens before the answer');

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(setup.asked, ['remove']);
    expect(container.read(sshRelaysProvider), isEmpty);
  });

  testWidgets('a host deleted from Settings leaves a row that can only be '
      'forgotten, and says why', (tester) async {
    addRelay();
    final container = await pump(tester);

    expect(find.textContaining('was removed from Settings'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Check'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Forget'));
    await tester.pumpAndSettle();
    expect(container.read(sshRelaysProvider), isEmpty);
  });

  testWidgets('while the machine is being asked the row says so, and its '
      'buttons wait', (tester) async {
    addHost();
    addRelay();
    final data = await server.override();
    final never = Completer<SshRelayReading>();
    final container = ProviderContainer(
      overrides: [
        data,
        clockProvider.overrideWithValue(FixedClock(testTime)),
        remoteAccessControllerProvider.overrideWith(_Access.new),
        sshRelaySetupFactoryProvider.overrideWithValue(
          (host, port) => never.future.then((_) => throw StateError('unused')),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SshRelaysPanel())),
      ),
    );
    await tester.tap(find.widgetWithText(TextButton, 'Check'));
    await tester.pump();

    expect(find.text('Asking the machine…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Remove'))
          .onPressed,
      isNull,
    );
  });
}

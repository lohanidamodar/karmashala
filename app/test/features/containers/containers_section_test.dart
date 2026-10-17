import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/containers/data/containers_client.dart';
import 'package:karmashala/src/features/containers/presentation/containers_section.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_hosts_section.dart';
import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_ui/tokens.dart' show DialogWidth, Insets;

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

SshHost _sshHost(String id, String name) => SshHost(
  id: id,
  name: name,
  host: '$name.example',
  port: 22,
  username: 'karma',
  authMethod: SshAuthMethod.password,
  createdAt: testTime,
);

SshHost _container({String id = 'c1', String name = 'sandbox'}) => SshHost(
  id: id,
  name: name,
  host: 'localhost',
  port: 41001,
  username: 'dev',
  authMethod: SshAuthMethod.privateKey,
  privateKey: const EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\data\containers\keys\c1',
  ),
  createdAt: testTime,
  container: const SshContainer(
    environmentId: 'wsl:Ubuntu',
    name: 'ks-sandbox',
    id: 'abc',
    image: 'debian:13',
    cpus: 2,
    memoryMb: 4096,
    agents: ['claude', 'codex'],
  ),
);

void main() {
  late FakeDataServer server;

  setUp(() {
    server = FakeDataServer();
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv(id: 'wsl:Ubuntu', distro: 'Ubuntu'));
    final pi = _sshHost('pi', 'pi-lab');
    server.sshHostRows.upsert(pi);
    server.environmentRows.upsert(sshEnvironment(pi));
    server.sshWork.onContainer = (request) => switch (request) {
      ContainerHostCheck(environmentId: 'ssh:pi') => const HostCheck(
        canHost: false,
        problem: "karma can't use Docker on pi-lab: not in the docker group.",
      ),
      ContainerHostCheck() => const HostCheck(
        canHost: true,
        dockerVersion: '27.3.1',
        architecture: 'x86_64',
        cores: 8,
        freeMemoryMb: 16384,
        freeDiskMb: 80000,
      ),
      ContainerStatus() => ContainerState.running,
      ContainerPower(:final action) =>
        action == ContainerPowerAction.stop
            ? ContainerState.stopped
            : ContainerState.running,
      ContainerCreate() => throw const DataRefused(
        DataRefusalCode.failed,
        'The setup inside the container failed; its log is above.',
      ),
      _ => const DataAck(),
    };
  });

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final workspace = await server.override();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          workspace,
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Column(children: [ContainersSection(), SshHostsSection()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('containers-new')));
    await tester.pumpAndSettle();
  }

  /// Taps [key] once it is scrolled into view.
  Future<void> tapKey(WidgetTester tester, String key) async {
    final found = find.byKey(ValueKey(key));
    // To the top of the dialog's scroll: at its bottom edge the actions
    // cover it, and a host row at a large text size is half a phone tall.
    final vertical = find
        .ancestor(of: found, matching: find.byType(Scrollable))
        .evaluate()
        .map((e) => (e as StatefulElement).state as ScrollableState)
        .where((s) => s.axisDirection == AxisDirection.down)
        .firstOrNull;
    if (vertical != null) {
      await vertical.position.ensureVisible(tester.renderObject(found));
    }
    await tester.pumpAndSettle();
    // Near its top: a tall row's middle can still be under the actions.
    final box = tester.getRect(found);
    await tester.tapAt(
      Offset(box.center.dx, box.top + (box.height < 48 ? box.height / 2 : 24)),
    );
    await tester.pumpAndSettle();
  }

  /// The row's menu, as a right-click opens it.
  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey('container-c1')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('says what a container is when there are none', (tester) async {
    await pump(tester);
    expect(find.textContaining('No containers yet'), findsOneWidget);
  });

  testWidgets('the form shows each host with its check, and greys the one '
      'that cannot', (tester) async {
    await pump(tester);
    await openDialog(tester);

    expect(find.text('Ubuntu · WSL on this PC'), findsOneWidget);
    expect(
      find.text('Docker 27.3.1 · x86_64 · 8 cores · 16 GB free · 78.1 GB disk'),
      findsOneWidget,
    );
    expect(find.text('pi-lab · SSH'), findsOneWidget);
    expect(
      find.text("karma can't use Docker on pi-lab: not in the docker group."),
      findsOneWidget,
    );
    final pi = tester.widget<RadioListTile<String>>(
      find.byKey(const ValueKey('container-host-ssh:pi')),
    );
    expect(pi.enabled, isFalse);
    // Nothing chosen yet: nothing to create.
    final create = tester.widget<FilledButton>(
      find.byKey(const ValueKey('container-create')),
    );
    expect(create.onPressed, isNull);
  });

  testWidgets('create sends what the form says, then the row shows its '
      'progress and why it failed', (tester) async {
    final gate = server.sshWork.createGate = Completer<void>();
    await pump(tester);
    await openDialog(tester);

    await tester.enterText(
      find.byKey(const ValueKey('container-name')),
      'sandbox',
    );
    await tapKey(tester, 'container-host-wsl:Ubuntu');
    await tapKey(tester, 'distro-fedora');
    await tapKey(tester, 'agent-gemini');
    await tester.pumpAndSettle();
    await tapKey(tester, 'container-create');
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Creating · 1 of 6'), findsOneWidget);
    // The server has not answered yet: the row is followed by its id.
    final row = tester.widget(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'container-creating-',
            ),
      ),
    );
    final machineId = (row.key! as ValueKey<String>).value.substring(
      'container-creating-'.length,
    );

    server.sshWork.tellContainerProgress(
      ContainerProgress(
        machineId: machineId,
        step: ContainerStep.settingUp,
        line: 'karmashala: installing ssh, sudo, curl and git with dnf',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Creating · 4 of 6'), findsOneWidget);
    expect(
      find.textContaining('installing ssh, sudo, curl and git'),
      findsOneWidget,
    );

    gate.complete();
    await tester.pumpAndSettle();
    final create = server.sshWork.containerRequests
        .whereType<ContainerCreate>()
        .single;
    expect(create.machineId, machineId);
    expect(create.environmentId, 'wsl:Ubuntu');
    expect(create.spec.name, 'sandbox');
    expect(create.spec.distro, ContainerDistro.fedora);
    expect(create.spec.cpus, 2);
    expect(create.spec.memoryMb, 4096);
    expect(create.spec.agents, [
      ContainerAgentCli.claude,
      ContainerAgentCli.codex,
      ContainerAgentCli.gemini,
    ]);
    expect(find.text('Failed'), findsOneWidget);
    expect(
      find.text('The setup inside the container failed; its log is above.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Failed'), findsNothing);
  });

  testWidgets('a container is listed here, not among the SSH hosts, with '
      'its host and what it was made with', (tester) async {
    server.sshHostRows.upsert(_container());
    server.environmentRows.upsert(sshEnvironment(_container()));
    await pump(tester);

    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('· on Ubuntu'), findsOneWidget);
    expect(
      find.text('Debian 13 · 2 CPUs · 4 GB · Claude Code · Codex'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('container-terminal-c1')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SshHostsSection),
        matching: find.textContaining('sandbox'),
      ),
      findsNothing,
    );
  });

  testWidgets('stop and delete go to the server; delete asks first, with '
      'the home folder kept unless ticked', (tester) async {
    server.sshHostRows.upsert(_container());
    server.environmentRows.upsert(sshEnvironment(_container()));
    await pump(tester);

    await openMenu(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop').last);
    await tester.pumpAndSettle();
    expect(
      server.sshWork.containerRequests.whereType<ContainerPower>().single,
      isA<ContainerPower>()
          .having((r) => r.hostId, 'hostId', 'c1')
          .having((r) => r.action, 'action', ContainerPowerAction.stop),
    );

    await openMenu(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…').last);
    await tester.pumpAndSettle();
    expect(find.text('Delete sandbox?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      server.sshWork.containerRequests.whereType<ContainerDelete>(),
      isEmpty,
    );

    await openMenu(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…').last);
    await tester.pumpAndSettle();
    await tapKey(tester, 'container-delete-home');
    await tapKey(tester, 'container-delete-confirm');
    await tester.pumpAndSettle();
    final delete = server.sshWork.containerRequests
        .whereType<ContainerDelete>()
        .single;
    expect(delete.hostId, 'c1');
    expect(delete.withHome, isTrue);
  });

  testWidgets('an older server is said plainly', (tester) async {
    server.sshWork.onContainer = (request) => throw const DataRefused.invalid(
      'no data request is called "containers.check"',
    );
    await pump(tester);
    await openDialog(tester);
    expect(find.text(kContainersNeedNewerServer), findsWidgets);
  });

  for (final (size, scale) in const [
    (Size(360, 740), 1.0),
    (Size(360, 740), 1.6),
    (Size(1440, 900), 1.6),
  ]) {
    testWidgets('fits at ${size.width.round()} px and text ×$scale', (
      tester,
    ) async {
      server.sshHostRows.upsert(_container());
      server.environmentRows.upsert(sshEnvironment(_container()));
      final gate = server.sshWork.createGate = Completer<void>();
      await pump(tester, size: size, textScale: scale);
      expect(tester.takeException(), isNull);

      await openDialog(tester);
      expect(tester.takeException(), isNull);
      // The form keeps its design width on a desktop, and on a phone at a
      // large text size its fields still get room.
      final field = tester.getSize(
        find.byKey(const ValueKey('container-name')),
      );
      expect(
        field.width,
        lessThanOrEqualTo(DialogWidth.regular + 2 * Insets.xl),
      );
      expect(field.height, greaterThan(0));
      await tester.enterText(
        find.byKey(const ValueKey('container-name')),
        'second',
      );
      await tapKey(tester, 'container-host-wsl:Ubuntu');
      await tester.pumpAndSettle();
      await tapKey(tester, 'container-create');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Creating'), findsOneWidget);

      await openMenu(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete…').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      gate.complete();
      await tester.pumpAndSettle();
    });
  }
}

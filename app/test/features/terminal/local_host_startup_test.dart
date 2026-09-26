import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/terminal/application/local_host_startup.dart';
import 'package:karmashala_host/host_paths.dart';
import 'package:karmashala_host/lifecycle_client.dart' show HookEndpoint;
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';
import 'fake_instance.dart';

/// The session host is started as the app starts, whatever the panes setting
/// (the app's data lives there) — before the agents' hooks are installed and before the
/// lifecycle subscriber dials — so the first session's first turn is heard.
void main() {
  late Directory home;
  late AppDatabase db;
  late List<String> events;

  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala_host_startup_');
    db = AppDatabase.memory();
    events = [];
  });
  tearDown(() {
    db.close();
    removeTempDirectory(home);
  });

  ProviderContainer containerWith(_Access? access, {bool hostBacked = true}) {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        hostBackedLocalPanesProvider.overrideWithValue(hostBacked),
        localHostSessionAccessProvider.overrideWithValue(access),
        // The real source would dial [access]'s socket; this one records it.
        hostLifecycleSourceProvider.overrideWithValue(
          access == null || !hostBacked ? null : _Source(events),
        ),
        agentHookInstallationServiceProvider.overrideWith(
          (ref) => _Installer(ref, events),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  _Access access({Future<HostDeployment> Function()? start}) => _Access(
    HostPaths(Directory(p.join(home.path, 'host'))..createSync()),
    events,
    start,
  );

  test('the host starts once, then hooks install, then the subscriber '
      'dials', () async {
    final starting = Completer<HostDeployment>();
    final host = access(start: () => starting.future);
    final container = containerWith(host);

    // What AppShell does, and what the launch's hook sweep does.
    container.listen(hostLifecycleSubscriberProvider, (_, _) {});
    final startup = container.read(localHostStartupProvider)!;
    await pumpEventQueue();
    expect(events, ['start'], reason: 'nothing may run before the host is up');

    await HookEndpoint(
      port: 4242,
      token: 'host-token',
    ).write(host.paths.hookEndpointPath);
    starting.complete(_ready());
    final reading = await startup;
    await pumpEventQueue();

    expect(reading?.status, HostDeploymentStatus.ready);
    expect(events, ['start', 'install 4242', 'dial']);
    expect(host.starts, 1);
    expect(
      identical(container.read(localHostStartupProvider), startup),
      isTrue,
    );
  });

  test('a start that throws leaves the app usable: the feed still dials and '
      'no hook is pointed at a host that is not there', () async {
    final host = access(start: () async => throw StateError('no serve'));
    final container = containerWith(host);

    container.listen(hostLifecycleSubscriberProvider, (_, _) {});
    final reading = await container.read(localHostStartupProvider)!;
    await pumpEventQueue();

    expect(reading, isNull);
    expect(events, ['start', 'dial']);
  });

  test(
    'a host that cannot start is reported, and the feed still dials',
    () async {
      final host = access(
        start: () async => HostDeployment(
          status: HostDeploymentStatus.cannotStart,
          observedAt: DateTime.now(),
          reason: 'exited before serving',
        ),
      );
      final container = containerWith(host);

      container.listen(hostLifecycleSubscriberProvider, (_, _) {});
      final reading = await container.read(localHostStartupProvider)!;
      await pumpEventQueue();

      expect(reading?.status, HostDeploymentStatus.cannotStart);
      expect(events, ['start', 'dial']);
    },
  );

  test('with host-backed panes off, the host still starts — the data '
      'lives there — but no hook points at it and no feed dials', () async {
    final host = access();
    final container = containerWith(host, hostBacked: false);

    container.listen(hostLifecycleSubscriberProvider, (_, _) {});
    final reading = await container.read(localHostStartupProvider)!;
    await pumpEventQueue();

    expect(reading?.status, HostDeploymentStatus.ready);
    expect(container.read(hostLifecycleSubscriberProvider), isNull);
    expect(host.starts, 1);
    expect(events, ['start']);
  });

  test('with no host reachable here, nothing is started', () {
    final container = containerWith(null);
    expect(container.read(localHostStartupProvider), isNull);
  });
}

HostDeployment _ready() => HostDeployment(
  status: HostDeploymentStatus.ready,
  observedAt: DateTime.now(),
  reason: 'Started the session host on this machine.',
  restartedByUs: true,
);

/// A host access that starts nothing real: [deployment] records the start and
/// answers what the test hands it.
class _Access extends LocalHostSessionAccess {
  _Access(HostPaths paths, this.events, this.start) : super(paths: paths);

  final List<String> events;
  final Future<HostDeployment> Function()? start;
  var starts = 0;

  @override
  Future<HostDeployment> deployment() {
    starts++;
    events.add('start');
    return (start ?? () async => _ready())();
  }
}

/// A host feed nobody answers; each dial is recorded.
class _Source implements HostLifecycleSource {
  _Source(this.events);
  final List<String> events;

  @override
  Future<HostLifecycleFeed?> open({List<String> runByClient = const []}) async {
    events.add('dial');
    return null;
  }
}

/// Installs nothing; records the port each sweep was pointed at.
class _Installer extends AgentHookInstallationService {
  _Installer(super.ref, this.events);
  final List<String> events;

  @override
  Future<List<AgentHookInstallation>> installAll(
    AgentHookEndpoint endpoint,
  ) async {
    events.add('install ${endpoint.port}');
    return const [];
  }
}

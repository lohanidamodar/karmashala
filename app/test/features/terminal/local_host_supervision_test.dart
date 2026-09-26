import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala/src/features/settings/presentation/session_host_status_line.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/terminal/application/local_host_startup.dart';
import 'package:karmashala/src/features/terminal/presentation/session_host_banner.dart';
import 'package:karmashala_host/host_paths.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';
import 'fake_instance.dart';
import '../../support/test_machine.dart';

/// The app supervises this machine's host while it is open: a host that dies
/// is started again, and the lifecycle subscriber — with everything that rides
/// it — attaches to the new one.
void main() {
  late Directory home;
  late TestMachine db;

  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala_host_supervision_');
    db = TestMachine();
  });
  tearDown(() {
    removeTempDirectory(home);
  });

  test('a host that dies while the app is open is started again, and the '
      'subscriber attaches to the new one at once', () async {
    final host = _Host(
      HostPaths(Directory(p.join(home.path, 'host'))..createSync()),
    );
    final source = _Source(host);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        hostBackedLocalPanesProvider.overrideWithValue(true),
        localHostSessionAccessProvider.overrideWithValue(host),
        localHostSupervisorProvider.overrideWith((ref) {
          final supervisor = LocalHostSupervisor(
            access: host,
            backoff: const [Duration(milliseconds: 10)],
          );
          ref.onDispose(supervisor.dispose);
          return supervisor;
        }),
        hostLifecycleSourceProvider.overrideWithValue(source),
        agentHookInstallationServiceProvider.overrideWith(_Installer.new),
      ],
    );
    addTearDown(container.dispose);

    container.listen(hostLifecycleSubscriberProvider, (_, _) {});
    await container.read(localHostStartupProvider);
    await pumpEventQueue();
    final subscriber = container.read(hostLifecycleSubscriberProvider)!;
    final supervisor = container.read(localHostSupervisorProvider)!;
    expect(source.opened, 1);
    expect(subscriber.isWatching, isTrue);
    expect(subscriber.isRunning('s1'), isTrue);
    expect(supervisor.state.pid, 100);

    // The host is SIGTERM'd: its socket goes, and the lifecycle link closes.
    final restarted = supervisor.restarted.first;
    host.up = false;
    await source.links.last.close();
    await restarted.timeout(const Duration(seconds: 5));
    await pumpEventQueue();

    expect(host.starts, 2, reason: 'the launch, then the restart');
    expect(supervisor.state.phase, HostSupervisionPhase.running);
    expect(supervisor.state.pid, 101);
    // Dialled at once on the restart, not on the subscriber's own backoff.
    expect(source.opened, 2);
    expect(subscriber.isWatching, isTrue);
    // The new host's snapshot: what died with the old one is not running.
    expect(subscriber.isRunning('s1'), isFalse);
  });

  group('the banner', () {
    Future<_FakeSupervisor> pumpBanner(
      WidgetTester tester,
      HostSupervision supervision,
    ) async {
      final supervisor = _FakeSupervisor(
        _Host(HostPaths(Directory(p.join(home.path, 'host'))..createSync())),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localHostSessionAccessProvider.overrideWithValue(supervisor.access),
            hostBackedLocalPanesProvider.overrideWithValue(true),
            localHostSupervisorProvider.overrideWithValue(supervisor),
            localHostSupervisionProvider.overrideWith(
              (ref) => Stream.value(supervision),
            ),
          ],
          child: const MaterialApp(
            home: SessionHostBanner(child: Scaffold(body: Text('shell'))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return supervisor;
    }

    HostSupervision outdated(List<String>? held) => HostSupervision(
      phase: HostSupervisionPhase.outdated,
      observedAt: DateTime.now(),
      reason: 'older',
      reading: HostDeployment(
        status: HostDeploymentStatus.protocolMismatch,
        observedAt: DateTime.now(),
        reason: 'older',
        hostOutdated: true,
        liveSessionIds: held,
      ),
    );

    final restart = find.byKey(const ValueKey('session_host_banner_restart'));

    testWidgets('an older host holding sessions names how many a restart '
        'ends, and ends them only once the person confirms', (tester) async {
      final supervisor = await pumpBanner(tester, outdated(const ['a', 'b']));
      expect(find.text('Restart host (ends 2 sessions)'), findsOneWidget);
      expect(find.textContaining('speaking another protocol'), findsOneWidget);

      await tester.tap(restart);
      await tester.pumpAndSettle();
      expect(supervisor.restarts, isEmpty, reason: 'nothing before the answer');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Restart'),
        ),
      );
      await tester.pumpAndSettle();
      expect(supervisor.restarts, [true]);
    });

    testWidgets('an older host holding nothing needs nobody', (tester) async {
      await pumpBanner(tester, outdated(const []));
      expect(restart, findsNothing);
    });

    testWidgets('a crash loop shows the reason and the host\'s last words, and '
        'restarts without asking: it holds nothing', (tester) async {
      final supervisor = await pumpBanner(
        tester,
        HostSupervision(
          phase: HostSupervisionPhase.stopped,
          observedAt: DateTime.now(),
          reason: 'It was started again 6 times in a row',
          lastOutput: const ['fatal: the store is locked'],
        ),
      );
      expect(find.textContaining('Session host: stopped'), findsOneWidget);
      expect(find.textContaining('fatal: the store is locked'), findsOneWidget);
      await tester.tap(restart);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(supervisor.restarts, [false]);
    });

    testWidgets('a running host shows nothing', (tester) async {
      await pumpBanner(
        tester,
        HostSupervision(
          phase: HostSupervisionPhase.running,
          observedAt: DateTime.now(),
        ),
      );
      expect(find.byKey(const ValueKey('session_host_banner')), findsNothing);
      expect(find.text('shell'), findsOneWidget);
    });
  });

  group('the Settings row says what supervision is doing', () {
    final now = DateTime.utc(2026, 9, 25, 12);

    test('restarting, with the attempt and when the next one runs', () {
      final line = sessionHostStatusText(
        null,
        now: now,
        supervision: HostSupervision(
          phase: HostSupervisionPhase.restarting,
          observedAt: now,
          reason: 'the lifecycle link to it closed',
          attempt: 2,
          maxAttempts: 6,
          nextAttemptAt: now.add(const Duration(seconds: 5)),
        ),
      );
      expect(line, contains('Session host: restarting…'));
      expect(line, contains('attempt 2 of 6'));
      expect(line, contains('next in 5s'));
      expect(line, contains('the lifecycle link to it closed'));
    });

    test('stopped, with the reason and the host\'s last lines', () {
      final line = sessionHostStatusText(
        null,
        supervision: HostSupervision(
          phase: HostSupervisionPhase.stopped,
          observedAt: now,
          reason: 'It was started again 6 times in a row',
          lastOutput: const ['one', 'two'],
        ),
      );
      expect(line, startsWith('Session host: stopped: It was started again'));
      expect(line, contains('one ⏎ two'));
    });

    test('stopped, with when it is looked at again', () {
      final line = sessionHostStatusText(
        null,
        now: now,
        supervision: HostSupervision(
          phase: HostSupervisionPhase.stopped,
          observedAt: now,
          reason: 'No karmashala_host beside this app.',
          nextAttemptAt: now.add(const Duration(seconds: 30)),
        ),
      );
      expect(line, contains('No karmashala_host beside this app.'));
      expect(line, contains('looked at again in 30s'));
    });

    test('running, with its pid', () {
      final line = sessionHostStatusText(
        HostDeployment(
          status: HostDeploymentStatus.ready,
          observedAt: now,
          reason: 'answering',
          hostVersion: '0.2.0',
          hostPid: 4321,
        ),
        now: now,
        supervision: HostSupervision(
          phase: HostSupervisionPhase.running,
          observedAt: now,
        ),
      );
      expect(line, contains('karmashala_host 0.2.0 is running (pid 4321)'));
    });

    test('the restart button names what it ends', () {
      HostDeployment older(List<String>? held) => HostDeployment(
        status: HostDeploymentStatus.ready,
        observedAt: now,
        reason: 'older',
        hostOutdated: true,
        liveSessionIds: held,
      );
      expect(
        sessionHostRestartLabel(older(['a'])),
        'Restart host (ends 1 session)',
      );
      expect(
        sessionHostRestartLabel(older(null)),
        'Restart host (ends its sessions)',
      );
      expect(sessionHostRestartLabel(older([])), 'Restart host');
      expect(
        sessionHostRestartLabel(
          HostDeployment(
            status: HostDeploymentStatus.ready,
            observedAt: now,
            reason: 'current',
          ),
        ),
        'Restart',
      );
    });
  });
}

/// This machine's host, as the supervisor and the subscriber meet it: up or
/// not, and a new pid each time it is started again. Starts nothing real.
class _Host extends LocalHostSessionAccess {
  _Host(HostPaths paths) : super(paths: paths);

  var up = true;
  var pid = 100;
  var starts = 0;

  HostDeployment _ready({required bool started}) => HostDeployment(
    status: HostDeploymentStatus.ready,
    observedAt: DateTime.now(),
    reason: 'answering',
    hostVersion: '0.2.0',
    hostPid: pid,
    restartedByUs: started,
  );

  @override
  Future<HostDeployment> deployment() async {
    starts++;
    if (up) return _ready(started: false);
    up = true;
    pid++;
    return _ready(started: true);
  }

  @override
  Future<HostDeployment> observe() async => up
      ? _ready(started: false)
      : HostDeployment(
          status: HostDeploymentStatus.unknown,
          observedAt: DateTime.now(),
          reason: 'Nothing is listening; no host is running here.',
        );
}

/// The host's lifecycle feed: a link per dial while [host] is up. The first
/// host runs `s1`; one started after it runs nothing.
class _Source implements HostLifecycleSource {
  _Source(this.host);

  final _Host host;
  final links = <StreamController<SessionLifecycleEvent>>[];
  var opened = 0;

  @override
  Future<HostLifecycleFeed?> open({List<String> runByClient = const []}) async {
    if (!host.up) return null;
    opened++;
    final events = StreamController<SessionLifecycleEvent>();
    links.add(events);
    return HostLifecycleFeed(
      snapshot: [
        if (host.pid == 100)
          SessionFacts(
            hostSessionId: 'karmashala_s1',
            state: HostSessionState.running,
            observedAt: DateTime.now().toUtc(),
          ),
      ],
      events: events.stream,
      close: () async {
        if (!events.isClosed) await events.close();
      },
    );
  }
}

class _FakeSupervisor extends LocalHostSupervisor {
  _FakeSupervisor(_Host host) : super(access: host);

  final restarts = <bool>[];

  @override
  Future<HostDeployment?> restartNow({bool force = false}) async {
    restarts.add(force);
    return null;
  }
}

/// Installs nothing.
class _Installer extends AgentHookInstallationService {
  _Installer(super.ref);

  @override
  Future<List<AgentHookInstallation>> installAll(
    AgentHookEndpoint endpoint,
  ) async => const [];
}

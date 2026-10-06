import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/server/application/server_overview.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart';

/// What Settings → Server reads from this machine's host: the counts it can
/// ask for, and which of Restart and Stop can act.
void main() {
  final at = DateTime.utc(2026, 10, 6, 12);

  HostDeployment reading(
    HostDeploymentStatus status, {
    bool unresponsive = false,
    bool outdated = false,
    List<String>? live,
  }) => HostDeployment(
    status: status,
    observedAt: at,
    reason: status.name,
    hostVersion: '1.31.0',
    hostUnresponsive: unresponsive,
    hostOutdated: outdated,
    liveSessionIds: live,
  );

  SessionSummary session(String id, {required bool ended}) => SessionSummary(
    id: id,
    argv: const ['sh'],
    workingDirectory: null,
    pid: 1,
    columns: 80,
    rows: 24,
    startedAt: at,
    observedAt: at,
    totalBytes: 0,
    firstAvailableOffset: 0,
    writeHolder: null,
    lifecycle: ended
        ? SessionExited(0, at)
        : const SessionRunning(),
  );

  test('a running host is asked what it holds, live and ended', () async {
    final overview = await localServerOverview(
      reading: reading(HostDeploymentStatus.ready),
      supervision: null,
      listSessions: () async => [
        session('a', ended: false),
        session('b', ended: true),
        session('c', ended: true),
      ],
      version: '1.31.1',
    );
    expect(overview.state, ServerRunState.running);
    expect(overview.liveSessions, 1);
    expect(overview.endedSessions, 2);
    expect(describeSessionsHeld(overview), '1 running · 2 ended');
    expect(overview.versionsDiffer, isTrue);
    expect(overview.canRestart, isTrue);
    expect(overview.canStop, isTrue);
  });

  test('a host that would not list leaves both counts unknown', () async {
    final overview = await localServerOverview(
      reading: reading(HostDeploymentStatus.ready),
      supervision: null,
      listSessions: () async => throw StateError('no answer'),
    );
    expect(overview.liveSessions, isNull);
    expect(describeSessionsHeld(overview), isNull);
  });

  test('a host that will not answer is not asked again, and can only be '
      'restarted', () async {
    var asked = 0;
    final overview = await localServerOverview(
      reading: reading(HostDeploymentStatus.unknown, unresponsive: true),
      supervision: null,
      listSessions: () async {
        asked++;
        return const [];
      },
    );
    expect(asked, 0);
    expect(overview.liveSessions, isNull);
    expect(overview.canRestart, isTrue);
    expect(overview.canStop, isFalse);
  });

  test('an older host speaking another protocol says what it runs', () async {
    final overview = await localServerOverview(
      reading: reading(
        HostDeploymentStatus.protocolMismatch,
        outdated: true,
        live: const ['a', 'b'],
      ),
      supervision: null,
      listSessions: () async => throw StateError('other protocol'),
    );
    expect(overview.liveSessions, 2);
    expect(overview.canRestart, isTrue);
  });

  test('no host and none to start: nothing to restart or stop', () async {
    final overview = await localServerOverview(
      reading: reading(HostDeploymentStatus.noBinary),
      supervision: null,
      listSessions: null,
    );
    expect(overview.state, ServerRunState.stopped);
    expect(overview.canRestart, isFalse);
    expect(overview.canStop, isFalse);
  });

  test('nothing checked is not "stopped"', () async {
    final overview = await localServerOverview(
      reading: null,
      supervision: null,
      listSessions: null,
    );
    expect(overview.state, ServerRunState.unknown);
  });
}

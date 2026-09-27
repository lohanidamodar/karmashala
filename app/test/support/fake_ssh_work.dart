part of 'fake_data_server.dart';

/// The server's own SSH (slices 3a and 5d) as a test scripts it: what
/// `ssh.test` answers, the answers a window gave its questions, the
/// questions and connection states the server tells every window, and what
/// it answers about a box's host — its install reading, its sessions, its
/// relay, the port a phone dials and a pairing window. The app only asks.
class FakeSshWork {
  FakeSshWork._(this._server);

  final FakeDataServer _server;

  /// What `ssh.test` answers; a success by default.
  SshTestResult Function(SshTest request) onTest = (_) =>
      const SshTestResult(connected: true, message: 'Linux 6.18.0');

  /// Each `ssh.test` asked.
  final tests = <SshTest>[];

  /// Each `ssh.answerPrompt`, secret and all — what a window sent.
  final answers = <SshAnswerPrompt>[];

  /// Each `ssh.disconnect`, by host id.
  final disconnects = <String>[];

  /// What `ssh.deploy` answers; by default the host installed and running.
  late HostInstallReading Function(SshDeploy request) onDeploy = (request) =>
      boxReading(
        request.action == SshDeployAction.remove
            ? HostInstallState.notInstalled
            : HostInstallState.installed,
        running:
            request.action != SshDeployAction.stop &&
            request.action != SshDeployAction.remove,
      );

  /// Each `ssh.deploy` asked.
  final deploys = <SshDeploy>[];

  /// What each box's host holds, by host id (`ssh.hostSessions`).
  final hostSessions = <String, List<SessionSummary>>{};

  /// Set to refuse `ssh.hostSessions` in these words.
  String? hostSessionsRefusal;

  /// Each `ssh.endHostSession`, as (host, session).
  final endedHostSessions = <(String, String)>[];

  /// What `ssh.relaySetup` answers; a running relay by default.
  late SshBoxAnswer<SshRelayReading> Function(SshBoxRelay request) onRelay =
      (request) => SshBoxAnswer.of(
        SshRelayReading(
          status: request.action == SshRelayAction.stop ||
                  request.action == SshRelayAction.remove
              ? SshRelayStatus.stopped
              : SshRelayStatus.running,
          observedAt: _server._now(),
          reason: 'The relay answered on port ${request.port}.',
          port: request.port,
          url: Uri.parse(
            'ws://203.0.113.9:${request.port}/k/'
            'tokentokentokentokentokentokentoken',
          ),
        ),
      );

  /// Each `ssh.relaySetup` asked.
  final relays = <SshBoxRelay>[];

  /// What `ssh.companionEndpoint` answers; reachable by default.
  late SshBoxAnswer<CompanionEndpoint> Function(SshCompanionEndpoint request)
  onEndpoint = (request) => const SshBoxAnswer.of(
    CompanionEndpoint(
      address: '203.0.113.9',
      port: 47820,
      hostName: 'do-box',
      reachable: true,
      reason: 'The companion port answered.',
    ),
  );

  /// Each `ssh.companionEndpoint` asked.
  final endpoints = <SshCompanionEndpoint>[];

  /// What `ssh.pairPhone` answers; an open window by default.
  late SshBoxAnswer<PairingWindow> Function(SshPairPhone request) onPair =
      (request) => SshBoxAnswer.of(
        PairingWindow(
          status: PairingRequestStatus.open,
          observedAt: _server._now(),
          reason: 'Type this into the phone before it expires.',
          code: 'K7QM-3X2W',
          expiresAt: _server._now().add(const Duration(minutes: 5)),
        ),
      );

  /// Each `ssh.pairPhone` asked.
  final pairings = <SshPairPhone>[];

  /// A box host reading as the server would give it.
  HostInstallReading boxReading(
    HostInstallState state, {
    bool running = true,
    String reason = 'Looked just now.',
    String? installedVersion = '1.25.0',
    String? offeredVersion = '1.25.0',
    int? sessionsHeld,
    HostDeployment? deployment,
  }) => HostInstallReading(
    state: state,
    observedAt: _server._now(),
    reason: reason,
    installedVersion: state == HostInstallState.notInstalled
        ? null
        : installedVersion,
    offeredVersion: offeredVersion,
    running: state != HostInstallState.notInstalled && running,
    sessionsHeld: sessionsHeld,
    deployment: deployment,
  );

  /// The server tells every window: a connection moved, a question opened
  /// or closed.
  void tell(List<SshChange> changes) => _server._tell(null, changes);

  Object? _handle(SshWorkRequest<Object?> request) => switch (request) {
    final SshTest r => () {
      tests.add(r);
      return onTest(r);
    }(),
    SshDisconnect(:final hostId) => () {
      disconnects.add(hostId);
      return const DataAck();
    }(),
    final SshAnswerPrompt r => () {
      answers.add(r);
      return const DataAck();
    }(),
    final SshDeploy r => () {
      deploys.add(r);
      return onDeploy(r);
    }(),
    SshHostSessions(:final hostId) => () {
      if (hostSessionsRefusal case final words?) {
        throw DataRefused(DataRefusalCode.failed, words);
      }
      return hostSessions[hostId] ?? const <SessionSummary>[];
    }(),
    SshEndHostSession(:final hostId, :final sessionId) => () {
      endedHostSessions.add((hostId, sessionId));
      hostSessions[hostId]?.removeWhere((s) => s.id == sessionId);
      return const DataAck();
    }(),
    final SshBoxRelay r => () {
      relays.add(r);
      return onRelay(r);
    }(),
    final SshCompanionEndpoint r => () {
      endpoints.add(r);
      return onEndpoint(r);
    }(),
    final SshPairPhone r => () {
      pairings.add(r);
      return onPair(r);
    }(),
  };
}

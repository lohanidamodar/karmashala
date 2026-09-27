import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:test/test.dart';

/// The pure half of the host (slice 5d): how a box's session is named at the
/// server, the one frame 5d added, and the readings a client is told about a
/// box, each crossing JSON unchanged.
void main() {
  final at = DateTime.utc(2026, 9, 27, 12);

  test('a box\'s session is `ssh:<hostId>/<id>`, and only that parses', () {
    expect(boxSessionRef('h1', 'karmashala_s1'), 'ssh:h1/karmashala_s1');
    expect(parseBoxSessionRef('ssh:h1/karmashala_s1'), (
      hostId: 'h1',
      sessionId: 'karmashala_s1',
    ));
    expect(parseBoxSessionRef('karmashala_s1'), isNull);
    expect(parseBoxSessionRef('ssh:h1'), isNull);
    expect(parseBoxSessionRef('ssh:/x'), isNull);
    expect(parseBoxSessionRef('ssh:h1/'), isNull);
  });

  test('detach is 0x40, carries only its ref, and 0xf0/0xf1 are unchanged', () {
    expect(MessageType.detach.code, 0x40);
    final frame = const DetachMessage(9).toFrame();
    expect(frame.sessionRef, 9);
    expect(frame.payload, isEmpty);
    expect(
      (decodeMessage(FrameParser().add(frame.encode()).single) as DetachMessage)
          .sessionRef,
      9,
    );
    expect(MessageType.stopCheck.code, 0xf0);
    expect(MessageType.stopCheckAnswer.code, 0xf1);
    expect(kProtocolVersion, 30);
  });

  test('an install reading crosses JSON whole, its deploy and platform '
      'included', () {
    final reading = HostInstallReading(
      state: HostInstallState.outdated,
      observedAt: at,
      reason: 'An older host runs there.',
      platform: HostPlatform(
        operatingSystem: 'linux',
        architecture: 'arm64',
        libc: HostLibc.glibc,
        observedAt: at,
      ),
      installedVersion: '1.24.0',
      offeredVersion: '1.25.0',
      running: true,
      sessionsHeld: 2,
      remotePath: '/home/dev/.karmashala/bin/x/bin/karmashala_host',
      deployment: HostDeployment(
        status: HostDeploymentStatus.cannotInstall,
        observedAt: at,
        reason: 'no tar',
        privileged: const PrivilegedCommand(
          command: 'sudo apt-get install -y tar',
          does: 'Installs tar.',
          why: 'It needs root.',
        ),
      ),
      availableTargets: const ['linux-arm64'],
    );
    final back = HostInstallReading.fromJson(reading.toJson());
    expect(back.label, reading.label);
    expect(back.label, 'older than the server\'s (1.24.0 → 1.25.0), running');
    expect(back.sessionsHeld, 2);
    expect(back.platform?.targetKey, 'linux-arm64');
    expect(back.deployment?.privileged, reading.deployment?.privileged);
    expect(back.availableTargets, ['linux-arm64']);
  });

  test('a relay reading keeps its URL (the token) out of toString', () {
    final reading = SshRelayReading(
      status: SshRelayStatus.running,
      observedAt: at,
      reason: 'It answered.',
      port: 8787,
      url: Uri.parse('ws://203.0.113.9:8787/k/SECRET_TOKEN_VALUE'),
    );
    final back = SshRelayReading.fromJson(reading.toJson());
    expect(back.url, reading.url);
    expect(back.isServing, isTrue);
    expect('$back', isNot(contains('SECRET')));
  });

  test('an endpoint and a pairing window cross JSON whole', () {
    const endpoint = CompanionEndpoint(
      address: '203.0.113.9',
      port: 47820,
      hostName: 'do-box',
      reachable: false,
      reason: 'The port is shut.',
      command: 'sudo ufw allow 47820/tcp',
      outsideTheMachine: true,
    );
    final back = CompanionEndpoint.fromJson(endpoint.toJson());
    expect(back.authority, '203.0.113.9:47820');
    expect(back.outsideTheMachine, isTrue);
    expect(back.command, endpoint.command);

    final window = PairingWindow(
      status: PairingRequestStatus.open,
      observedAt: at,
      reason: 'Type this.',
      code: 'K7QM-3X2W',
      expiresAt: at.add(const Duration(minutes: 5)),
    );
    final again = PairingWindow.fromJson(window.toJson());
    expect(again.isOpen, isTrue);
    expect(again.code, 'K7QM-3X2W');
    expect(again.expiresAt, window.expiresAt);
  });

  test('a box session\'s summary keeps an unknown exit unknown', () {
    final summary = SessionSummary(
      id: 'karmashala_s1',
      argv: const ['claude'],
      workingDirectory: '/home/dev/api',
      pid: 7,
      columns: 80,
      rows: 24,
      startedAt: at,
      observedAt: at,
      totalBytes: 10,
      firstAvailableOffset: 0,
      lifecycle: SessionEndedWithoutCode(at, 'the session host stopped'),
      writeHolder: null,
    );
    final back = sessionSummaryFromJson(sessionSummaryToJson(summary));
    expect(back.lifecycle.hasEnded, isTrue);
    expect(back.lifecycle.exitCode, isNull);
    expect(back.lifecycle.describe(), contains('the session host stopped'));
  });
}

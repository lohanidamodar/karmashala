import 'dart:typed_data';

import 'package:karmashala_ssh_host/host.dart';
import 'package:test/test.dart';

/// A machine that answers the one detect-and-open script, and a dial that can
/// be told what the network says. Both halves matter: the whole point is that a
/// rule added and a port reachable are different facts.
class _Box implements HostDeployTarget {
  /// What the open script prints: ufw, firewalld, nosudo, unknown, none, or a
  /// surprise. Set per test rather than constructed, because which one a
  /// machine answers is the variable under test.
  String firewall = 'none';
  final commands = <String>[];

  @override
  String get address => 'box.example';

  @override
  Future<RemoteRun> run(String command) async {
    commands.add(command);
    return RemoteRun(0, '$firewall\n', '');
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {}

  @override
  Future<RemoteChannel> exec(String command) => throw UnimplementedError();
}

void main() {
  late _Box box;
  late List<bool> dialAnswers;
  late int dials;

  setUp(() {
    box = _Box();
    dialAnswers = [];
    dials = 0;
  });

  CompanionPortSetup setupOn(_Box target) => CompanionPortSetup(
    target: target,
    clock: () => DateTime.utc(2026, 9, 16),
    dial: (_, _, _) async {
      final answer = dialAnswers[dials.clamp(0, dialAnswers.length - 1)];
      dials++;
      return answer;
    },
  );

  test('a port that already answers is left alone entirely', () async {
    dialAnswers = [true];

    final reading = await setupOn(box).ensureOpen(47820);

    expect(reading.status, PortStatus.alreadyReachable);
    expect(reading.isReachable, isTrue);
    // The load-bearing assertion: nothing ran, so no sudo was asked for and no
    // rule was added to a machine that did not need one.
    expect(box.commands, isEmpty);
  });

  test('a shut port is opened, and the dial is what says so', () async {
    dialAnswers = [false, true];
    box.firewall = 'ufw';

    final reading = await setupOn(box).ensureOpen(47820);

    expect(reading.status, PortStatus.opened);
    expect(reading.reason, contains('ufw'));
    expect(reading.reason, contains('answers now'));
    expect(dials, 2, reason: 'opened is a claim about the second dial');
  });

  test(
    'a rule that went in while the port stayed shut names the provider',
    () async {
      // The case this whole class exists for: `ufw allow` exits 0, and a security
      // group nothing on the machine can see is still dropping the packets.
      dialAnswers = [false, false];
      box.firewall = 'ufw';

      final reading = await setupOn(box).ensureOpen(47820);

      expect(reading.status, PortStatus.ruleAddedStillShut);
      expect(reading.isReachable, isFalse);
      expect(reading.reason, contains('outside the machine'));
      expect(reading.reason, contains('provider'));
      expect(reading.outsideTheMachine, isTrue);
      expect(reading.privileged, isNull);
    },
  );

  test('a sudo that wants a password is a command for a terminal, exactly', () async {
    for (final (said, command) in [
      ('nosudo-ufw', 'sudo ufw allow 47820/tcp'),
      (
        'nosudo-firewalld',
        'sudo firewall-cmd --add-port=47820/tcp --permanent && sudo firewall-cmd --reload',
      ),
    ]) {
      dialAnswers = [false, false];
      dials = 0;
      box.firewall = said;

      final reading = await setupOn(box).ensureOpen(47820);

      expect(reading.status, PortStatus.couldNotOpen, reason: said);
      // The machine's own firewall, named — never "or your firewall's equivalent".
      expect(reading.privileged?.command, command);
      expect(reading.command, command);
      expect(reading.privileged?.does, contains('47820'));
      expect(reading.privileged?.why, contains('password'));
      expect(reading.outsideTheMachine, isFalse);
      // Never dialled a second time: nothing was changed, so nothing could have.
      expect(dials, 1);
    }
  });

  test(
    'after the command was run by hand, a still-shut port is the provider\'s',
    () async {
      dialAnswers = [false];
      box.firewall = 'nosudo-ufw';

      final reading = await setupOn(
        box,
      ).ensureOpen(47820, ruleAddedByHand: true);

      expect(reading.status, PortStatus.ruleAddedStillShut);
      expect(reading.outsideTheMachine, isTrue);
      // More sudo is not the remedy for a firewall the machine cannot see.
      expect(reading.privileged, isNull);
      expect(reading.reason, contains('DigitalOcean'));
      expect(reading.reason, contains('security group'));
      expect(reading.reason, contains('sudo ufw allow 47820/tcp'));
    },
  );

  test(
    '"check again" is the dial, and an open port needs nothing else',
    () async {
      dialAnswers = [true];
      box.firewall = 'nosudo-ufw';

      final reading = await setupOn(
        box,
      ).ensureOpen(47820, ruleAddedByHand: true);

      expect(reading.status, PortStatus.alreadyReachable);
      expect(box.commands, isEmpty);
    },
  );

  test('a firewall that is installed and switched off is not blamed', () async {
    // Ubuntu ships ufw installed and inactive; a rule there changes nothing.
    dialAnswers = [false];
    box.firewall = 'inactive';

    final reading = await setupOn(box).ensureOpen(47820);

    expect(reading.status, PortStatus.couldNotOpen);
    expect(reading.privileged, isNull);
    expect(reading.command, isNull);
    expect(reading.outsideTheMachine, isTrue);
    expect(reading.reason, contains('switched off'));
    expect(reading.reason, contains('DigitalOcean'));
  });

  test('a rule the firewall refused says so rather than "failed"', () async {
    dialAnswers = [false];
    box.firewall = 'failed-ufw';

    final reading = await setupOn(box).ensureOpen(47820);

    expect(reading.status, PortStatus.couldNotOpen);
    expect(reading.reason, contains('ufw refused'));
    expect(reading.privileged?.command, 'sudo ufw allow 47820/tcp');
  });

  test(
    'root needs no sudo, and the script reads evidence before acting',
    () async {
      dialAnswers = [false, true];
      box.firewall = 'ufw';

      await setupOn(box).ensureOpen(47820);

      final script = box.commands.single;
      expect(script, contains('id -u'));
      // Installed is not running: ufw's own switch and firewalld's own state.
      expect(script, contains('/etc/ufw/ufw.conf'));
      expect(script, contains('firewall-cmd --state'));
    },
  );

  test('a firewall this does not know quotes what the machine said', () async {
    dialAnswers = [false, false];
    box.firewall = 'nftables-maybe';

    final reading = await setupOn(box).ensureOpen(47820);

    expect(reading.status, PortStatus.couldNotOpen);
    expect(reading.reason, contains('nftables-maybe'));
    expect(reading.reason, contains('47820/tcp'));
  });

  test('finding no ufw is not the same as finding no firewall', () async {
    // The script looks for exactly two binaries. A box that drops packets with
    // nftables, or from a provider console, answers `none` to that question —
    // so a still-shut port must not be blamed on the provider when no rule was
    // ever added, and must not be called clear either.
    dialAnswers = [false, false];
    box.firewall = 'none';

    final reading = await setupOn(box).ensureOpen(47820);

    expect(reading.status, PortStatus.couldNotOpen);
    expect(reading.reason, contains('nothing'));
    expect(reading.reason, contains('nftables'));
    expect(
      reading.reason,
      isNot(contains('No firewall is running')),
      reason: 'two absent binaries do not prove a machine filters nothing',
    );
    expect(
      dials,
      1,
      reason: 'nothing changed, so there was nothing to re-dial',
    );
  });

  test('a box that filters with nftables is told, not guessed at', () async {
    // Measured 2026-09-16: WSL Arch has `nft` and neither `ufw` nor
    // `firewall-cmd`, which is what sent this branch looking for a third answer.
    dialAnswers = [false, false];
    box.firewall = 'unknown';

    final reading = await setupOn(box).ensureOpen(47820);

    expect(reading.status, PortStatus.couldNotOpen);
    expect(reading.reason, contains('nftables'));
    expect(reading.reason, contains('47820/tcp'));
  });

  test('the open script never prompts for a password', () async {
    dialAnswers = [false, true];
    box.firewall = 'ufw';

    await setupOn(box).ensureOpen(47820);

    // An SSH deploy that stopped for a password would hang with nobody there.
    expect(box.commands.single, contains('sudo -n'));
    expect(box.commands.single, isNot(contains(RegExp(r'sudo (?!-n)'))));
  });

  test('the verdicts are tokens a caller can match on', () {
    expect(PortStatus.alreadyReachable.token, 'PORT OPEN');
    expect(PortStatus.opened.token, 'PORT OPENED');
    expect(PortStatus.ruleAddedStillShut.token, 'PORT STILL SHUT');
    expect(PortStatus.couldNotOpen.token, 'PORT NOT OPENED');
  });
}

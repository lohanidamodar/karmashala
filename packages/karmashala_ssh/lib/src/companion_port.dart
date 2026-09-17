import 'dart:async';
import 'dart:io';

import 'package:karmashala_core/logging.dart';

import 'host_deploy_target.dart';

/// How a machine's companion port ended up, separated — like the store probe's
/// verdicts — by **who can fix it**.
enum PortStatus {
  /// Already reachable. Nothing was run and nothing was changed.
  alreadyReachable('PORT OPEN'),

  /// It was shut, a rule was added, and it is reachable now.
  opened('PORT OPENED'),

  /// A rule went in and the port is still shut from here. Almost always a
  /// second firewall in the provider's console, which no command on the machine
  /// can see or change. **The person has to do this one.**
  ruleAddedStillShut('PORT STILL SHUT'),

  /// Nothing here could add the rule: no sudo, or a firewall this does not
  /// know. The command to run is in the reason.
  couldNotOpen('PORT NOT OPENED');

  const PortStatus(this.token);

  final String token;
}

/// One reading about one machine's companion port, with the time it was taken.
class PortOpening {
  const PortOpening({
    required this.status,
    required this.observedAt,
    required this.reason,
    this.command,
  });

  final PortStatus status;
  final DateTime observedAt;

  /// One sentence, written for somebody deciding what to do next.
  final String reason;

  /// What to run by hand, when that is the remedy.
  final String? command;

  bool get isReachable =>
      status == PortStatus.alreadyReachable || status == PortStatus.opened;
}

/// Opens the companion port on a deployed machine, at setup, and proves it.
///
/// **A rule added is not a port reachable**, and the two are different facts.
/// §18 paid for that difference once already: the WSL switch address completed
/// a TCP handshake and then reset the first data segment, so "it connected" was
/// not "it works". A `ufw allow` that exits 0 proves a rule on *that* firewall;
/// a cloud box usually has a second one in a console no command here can see.
/// The reading that decides is a dial from outside.
///
/// **Nothing is changed on a guess.** The dial comes first, so a machine with
/// no firewall — most of them — is never touched, and `sudo` is never asked for
/// on its behalf. A rule is attempted only against evidence that the port is
/// shut, and the dial is repeated afterwards to see whether it helped.
class CompanionPortSetup {
  CompanionPortSetup({
    required this.target,
    String? dialHost,
    Future<bool> Function(String host, int port, Duration within)? dial,
    DateTime Function()? clock,
    AppLogger? logger,
    this.dialTimeout = const Duration(seconds: 5),
  }) : machine = dialHost ?? target.address,
       _dial = dial ?? _connect,
       _now = clock ?? DateTime.now,
       _logger = logger ?? AppLogger.named('ssh.port');

  final HostDeployTarget target;

  /// What is dialled and named in every sentence: the bare host. **Not**
  /// `target.address`, which for a real SSH target is the log label
  /// `user@host:22` — a lookup failure that reads as a shut port.
  final String machine;
  final Duration dialTimeout;
  final Future<bool> Function(String host, int port, Duration within) _dial;
  final DateTime Function() _now;
  final AppLogger _logger;

  /// The host must already be listening, or a dial says "shut" about a port
  /// nothing was ever going to answer on. The caller deploys and starts first.
  Future<PortOpening> ensureOpen(int port) async {
    if (await _reachable(port)) {
      return PortOpening(
        status: PortStatus.alreadyReachable,
        observedAt: _now(),
        reason:
            '$machine:$port answered. No firewall rule was needed, so '
            'nothing on the machine was changed.',
      );
    }

    final attempt = await _addRule(port);
    if (!attempt.ran) {
      return PortOpening(
        status: PortStatus.couldNotOpen,
        observedAt: _now(),
        reason: attempt.reason,
        command: attempt.command,
      );
    }

    if (await _reachable(port)) {
      return PortOpening(
        status: PortStatus.opened,
        observedAt: _now(),
        reason: '${attempt.reason} $machine:$port answers now.',
        command: attempt.command,
      );
    }

    return PortOpening(
      status: PortStatus.ruleAddedStillShut,
      observedAt: _now(),
      reason:
          '${attempt.reason} $machine:$port still does not answer, so '
          'something outside the machine is dropping it — a provider firewall '
          'or security group is the usual one, and nothing here can open that.',
      command: attempt.command,
    );
  }

  Future<bool> _reachable(int port) async {
    try {
      final answered = await _dial(machine, port, dialTimeout);
      _logger.debug('$machine:$port ${answered ? 'answered' : 'did not answer'}');
      return answered;
    } on Object catch (error) {
      _logger.debug('$machine:$port did not answer: $error');
      return false;
    }
  }

  /// Adds the rule with whichever firewall the machine runs. One command, so a
  /// machine running none is one round trip and no `sudo` prompt.
  Future<({bool ran, String reason, String? command})> _addRule(int port) async {
    final result = await target.run(_openScript(port));
    final said = result.stdout.trim().split('\n').last.trim();
    return switch (said) {
      'ufw' => (ran: true, reason: 'Opened $port with ufw.', command: 'sudo ufw allow $port/tcp'),
      'firewalld' => (
        ran: true,
        reason: 'Opened $port with firewalld.',
        command: 'sudo firewall-cmd --add-port=$port/tcp --permanent && sudo firewall-cmd --reload',
      ),
      'none' => (
        ran: false,
        // **Not** "no firewall is running" — all that was looked for is `ufw`
        // and `firewall-cmd`, and a box can drop packets with nftables, with
        // iptables, or from a console this cannot see. Saying the port is clear
        // because two binaries are absent is the confident false statement
        // every other verdict here is shaped to avoid.
        reason:
            'Found no `ufw` or `firewall-cmd` on $machine, so nothing '
            'there was changed. If it filters with nftables or iptables, or your '
            'provider has a firewall, $port/tcp has to be opened there.',
        command: null,
      ),
      'unknown' => (
        ran: false,
        reason:
            '$machine filters with nftables or iptables, which this '
            'does not open by hand — the rule depends on the chain it is going '
            'into. Open $port/tcp there.',
        command: null,
      ),
      'nosudo' => (
        ran: false,
        reason:
            'A firewall is running on $machine and this cannot change it '
            'without a password. Run the command below there, then deploy again.',
        command: 'sudo ufw allow $port/tcp   # or your firewall\'s equivalent',
      ),
      _ => (
        ran: false,
        reason:
            '$machine answered "${said.isEmpty ? 'nothing' : said}" when '
            'asked about its firewall, which this does not understand. Open '
            '$port/tcp there by hand.',
        command: null,
      ),
    };
  }

  /// Detects and opens in one shell round trip, and prints **one word** saying
  /// what it did. `sudo -n` never prompts: an SSH session that stopped for a
  /// password would hang a deploy with nobody there to type one.
  String _openScript(int port) =>
      '''
if command -v ufw >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo -n ufw allow $port/tcp >/dev/null 2>&1 && echo ufw || echo failed
elif command -v firewall-cmd >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo -n firewall-cmd --add-port=$port/tcp --permanent >/dev/null 2>&1 &&
    sudo -n firewall-cmd --reload >/dev/null 2>&1 && echo firewalld || echo failed
elif command -v ufw >/dev/null 2>&1 || command -v firewall-cmd >/dev/null 2>&1; then
  echo nosudo
elif command -v nft >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1; then
  echo unknown
else
  echo none
fi''';
}

/// A real dial, which is the only thing that answers the question.
Future<bool> _connect(String host, int port, Duration within) async {
  Socket? socket;
  try {
    socket = await Socket.connect(host, port, timeout: within);
    return true;
  } on SocketException {
    return false;
  } finally {
    socket?.destroy();
  }
}

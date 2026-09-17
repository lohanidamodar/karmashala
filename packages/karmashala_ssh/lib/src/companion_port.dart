import 'dart:async';
import 'dart:io';

import 'package:karmashala_core/logging.dart';

import 'host_deploy_target.dart';
import 'privileged_command.dart';

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
    this.privileged,
    this.outsideTheMachine = false,
  });

  final PortStatus status;
  final DateTime observedAt;

  /// One sentence, written for somebody deciding what to do next.
  final String reason;

  /// What to run by hand, when that is the remedy.
  final String? command;

  /// [command] with what it does and why it was not run from here, when the
  /// machine wants a password for it. Null when nothing is left to run there.
  final PrivilegedCommand? privileged;

  /// Whether what is shutting the port is past the machine's own firewall — a
  /// provider's — so more `sudo` on the box is not the remedy.
  final bool outsideTheMachine;

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
  /// nothing was ever going to answer on. [ruleAddedByHand] is "Check again"
  /// after the command this gave was run: the dial still decides, and the same
  /// command is not handed back.
  Future<PortOpening> ensureOpen(
    int port, {
    bool ruleAddedByHand = false,
  }) async {
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
      final byHand = attempt.privileged;
      if (ruleAddedByHand && byHand != null) {
        return PortOpening(
          status: PortStatus.ruleAddedStillShut,
          observedAt: _now(),
          reason:
              '$machine:$port still does not answer. If `${byHand.command}` '
              'ran without an error, the machine\'s own firewall is open and '
              'something outside the machine is dropping it. '
              '${providerFirewallHint(port)}',
          outsideTheMachine: true,
        );
      }
      return PortOpening(
        status: PortStatus.couldNotOpen,
        observedAt: _now(),
        reason: attempt.reason,
        command: attempt.command,
        privileged: byHand,
        outsideTheMachine: attempt.outside,
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
          'or security group is the usual one. ${providerFirewallHint(port)}',
      command: attempt.command,
      outsideTheMachine: true,
    );
  }

  Future<bool> _reachable(int port) async {
    try {
      final answered = await _dial(machine, port, dialTimeout);
      _logger.debug(
        '$machine:$port ${answered ? 'answered' : 'did not answer'}',
      );
      return answered;
    } on Object catch (error) {
      _logger.debug('$machine:$port did not answer: $error');
      return false;
    }
  }

  static String _ufwCommand(int port) => 'sudo ufw allow $port/tcp';

  static String _firewalldCommand(int port) =>
      'sudo firewall-cmd --add-port=$port/tcp --permanent && '
      'sudo firewall-cmd --reload';

  PrivilegedCommand _byHand(String firewall, String command, int port) =>
      PrivilegedCommand(
        command: command,
        does:
            'Allows inbound TCP $port through $firewall on $machine, and keeps '
            'the rule across restarts.',
        why:
            '`sudo` on $machine asks for a password, and Karmashala never asks '
            'for one or sends one — so this is yours to run, in a terminal '
            'there.',
      );

  /// Adds the rule with whichever firewall the machine runs. One command, so a
  /// machine running none is one round trip and no `sudo` prompt.
  Future<_RuleAttempt> _addRule(int port) async {
    final result = await target.run(_openScript(port));
    final said = result.stdout.trim().split('\n').last.trim();
    final isUfw = said.endsWith('ufw');
    final firewall = isUfw ? 'ufw' : 'firewalld';
    final command = isUfw ? _ufwCommand(port) : _firewalldCommand(port);
    return switch (said) {
      'ufw' || 'firewalld' => _RuleAttempt(
        ran: true,
        reason: 'Opened $port with $firewall.',
        command: command,
      ),
      'nosudo-ufw' || 'nosudo-firewalld' => _RuleAttempt(
        ran: false,
        reason:
            '$firewall is running on $machine and `sudo` there asks for a '
            'password, so $port/tcp was not opened. Run the command below in '
            'a terminal on $machine, then check again.',
        command: command,
        privileged: _byHand(firewall, command, port),
      ),
      'failed-ufw' || 'failed-firewalld' => _RuleAttempt(
        ran: false,
        reason:
            '$firewall refused the rule for $port/tcp on $machine. Running '
            'the command below in a terminal there shows why.',
        command: command,
        privileged: _byHand(firewall, command, port),
      ),
      'inactive' => _RuleAttempt(
        ran: false,
        reason:
            'The firewall on $machine is installed and switched off, so it is '
            'not what is shutting $port/tcp, and nothing there was changed. '
            '${providerFirewallHint(port)}',
        outside: true,
      ),
      'none' => _RuleAttempt(
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
      ),
      'unknown' => _RuleAttempt(
        ran: false,
        reason:
            '$machine filters with nftables or iptables, which this '
            'does not open by hand — the rule depends on the chain it is going '
            'into. Open $port/tcp there.',
      ),
      _ => _RuleAttempt(
        ran: false,
        reason:
            '$machine answered "${said.isEmpty ? 'nothing' : said}" when '
            'asked about its firewall, which this does not understand. Open '
            '$port/tcp there by hand.',
      ),
    };
  }

  /// Detects and opens in one round trip, and prints **one word**. `sudo -n`
  /// never prompts — a channel that stopped for a password would hang. Root
  /// needs no sudo, and a firewall that is off (read without root) is left.
  String _openScript(int port) =>
      '''
if [ "\$(id -u)" = 0 ]; then s=""; elif sudo -n true 2>/dev/null; then s="sudo -n"; else s=no; fi
has() { command -v "\$1" >/dev/null 2>&1; }
if has ufw && ! grep -q '^ENABLED=no' /etc/ufw/ufw.conf 2>/dev/null; then
  if [ "\$s" = no ]; then echo nosudo-ufw
  else \$s ufw allow $port/tcp >/dev/null 2>&1 && echo ufw || echo failed-ufw; fi
elif has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
  if [ "\$s" = no ]; then echo nosudo-firewalld
  else \$s firewall-cmd --add-port=$port/tcp --permanent >/dev/null 2>&1 &&
    \$s firewall-cmd --reload >/dev/null 2>&1 && echo firewalld || echo failed-firewalld; fi
elif has ufw || has firewall-cmd; then
  echo inactive
elif has nft || has iptables; then
  echo unknown
else
  echo none
fi''';
}

class _RuleAttempt {
  const _RuleAttempt({
    required this.ran,
    required this.reason,
    this.command,
    this.privileged,
    this.outside = false,
  });

  final bool ran;
  final String reason;
  final String? command;
  final PrivilegedCommand? privileged;
  final bool outside;
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';

import 'companion_port.dart';
import 'host_deploy_target.dart';
import 'privileged_command.dart';
import 'remote_detach.dart';
import 'remote_home.dart';
import 'ssh_host.dart';

/// The port a relay on a box listens on unless told otherwise: the relay's own
/// default, read from its contract (this package drives a relay over SSH and
/// never runs one, so it takes the contract and not the server).
const int kDefaultSshRelayPort = kDefaultRelayPort;

/// How the relay on one box ended up, separated by who can fix it.
enum SshRelayStatus {
  /// Running from this app version's bundle, and its health check answered
  /// from this computer.
  running,

  /// Nothing is running. Not a fault: never started, stopped, or the box
  /// restarted — like `serve`, the relay does not come back by itself.
  stopped,

  /// Running, from a bundle other than the one this app version deployed.
  /// `start()` replaces it, which is what "Update" means.
  outdated,

  /// Running on the box and not answering from here. A firewall, usually one
  /// in a provider's console; the reading carries the port check's own words.
  unreachable,

  /// It would not start: an old bundle with no `relay` command, a busy port,
  /// a token file that could not be made private.
  cannotStart,

  /// The machine could not be asked. A missing reading, not a negative one.
  unknown,
}

/// One reading about one box's relay, with the time it was taken.
class SshRelayReading {
  const SshRelayReading({
    required this.status,
    required this.observedAt,
    required this.reason,
    required this.port,
    this.command,
    this.privileged,
    this.outsideTheMachine = false,
    this.url,
    this.runningPath,
  });

  final SshRelayStatus status;
  final DateTime observedAt;

  /// One sentence, with its remedy when it has one. Never holds the token.
  final String reason;

  /// What to run by hand, when that is the remedy.
  final String? command;

  /// [command] as a step for a terminal on the box, when `sudo` there wants a
  /// password. Built from the port alone — never the token.
  final PrivilegedCommand? privileged;

  /// Whether what shuts the port is a firewall no command on the box can see.
  final bool outsideTheMachine;

  /// `ws://<address>:<port>/k/<token>` — what the desktop serves through and a
  /// pairing carries. Present whenever the token could be read. **Holds the
  /// access token: never log it, and [toString] leaves it out.**
  final Uri? url;

  final int port;

  /// The executable the running relay was started from.
  final String? runningPath;

  bool get isServing => status == SshRelayStatus.running;

  @override
  String toString() =>
      'SshRelayReading(${status.name}, port $port${url == null ? '' : ', url held'})';
}

/// Runs the relay a desktop serves through on one of its SSH hosts.
///
/// The bundle is the session host's — `karmashala_host relay` — so there is
/// nothing to upload here: the caller deploys the host and hands over the
/// executable it named. Supervision is the host's own as well, `setsid nohup`,
/// which means **it does not survive a reboot**; [start] brings it back.
///
/// The box mints the access token and this reads it back over SSH, so the
/// secret is never on a command line. The address is the one the desktop
/// connected with — a box cannot read its own public address.
class SshRelaySetup {
  SshRelaySetup({
    required this.host,
    required this.target,
    required this.remotePath,
    this.port = kDefaultSshRelayPort,
    CompanionPortSetup? ports,
    Future<bool> Function(Uri healthz, Duration within)? probe,
    DateTime Function()? clock,
    AppLogger? logger,
    this.probeTimeout = const Duration(seconds: 5),
  }) : _probe = probe ?? _httpHealthz,
       _now = clock ?? DateTime.now,
       _logger = logger ?? AppLogger.named('ssh.relay') {
    // The port check's evidence rule, with the dial swapped for a health check:
    // a rule is attempted only after the probe fails, and re-probed afterwards.
    _ports =
        ports ??
        CompanionPortSetup(
          target: target,
          dialHost: host.host,
          clock: clock,
          logger: _logger,
          dialTimeout: probeTimeout,
          dial: (_, _, within) => _probeHealth(within),
        );
  }

  final SshHost host;
  final HostDeployTarget target;

  /// `HostDeployment.remotePath`: the bundle executable this app version
  /// deployed. A relay running from any other path is [SshRelayStatus.outdated].
  final String remotePath;

  final int port;
  final Duration probeTimeout;

  late final CompanionPortSetup _ports;
  final Future<bool> Function(Uri healthz, Duration within) _probe;
  final DateTime Function() _now;
  final AppLogger _logger;

  /// The token last read from the box, for the probe. Never logged.
  String? _token;

  /// Asked once per setup: a home does not move between two readings.
  String? _home;

  static final _tokenShape = RegExp(r'^[A-Za-z0-9_-]{32,}$');

  /// Reads and changes nothing: what is running, from where, and whether it
  /// answers from here.
  Future<SshRelayReading> check() async {
    final state = await _inspect();
    if (state == null) return _unasked();
    if (!state.isRunning) return _stoppedReading(state);
    if (state.runningPath != remotePath) return _outdatedReading(state);
    if (state.token == null) return _noTokenReading(state);
    if (await _probeHealth(probeTimeout)) {
      return _reading(
        SshRelayStatus.running,
        'The relay on ${host.name} answered on port $port.',
        state: state,
      );
    }
    return _reading(
      SshRelayStatus.unreachable,
      'The relay is running on ${host.name}, but ${host.host}:$port did not '
      'answer from this computer. Start checks the firewall there.',
      state: state,
    );
  }

  /// Idempotent. Already running from this bundle: only proved. Running from
  /// another: stopped and started again, which is "Update". Then the port is
  /// opened against evidence and proved from here. [ruleAddedByHand] is
  /// "Check again" after the firewall command was run on the box.
  Future<SshRelayReading> start({bool ruleAddedByHand = false}) async {
    var state = await _inspect();
    if (state == null) return _unasked();

    if (state.isRunning && state.runningPath != remotePath) {
      if (!await _kill(state.directory)) {
        return _reading(
          SshRelayStatus.outdated,
          'The relay on ${host.name} is from another version and would not '
          'stop, so it was left running.',
          state: state,
        );
      }
      state = await _inspect();
      if (state == null) return _unasked();
    }

    if (!state.isRunning) {
      final refusal = await _launch(state.directory);
      if (refusal != null) return _reading(SshRelayStatus.cannotStart, refusal);
      state = await _inspect(waitForStart: true);
      if (state == null) return _unasked();
      if (!state.isRunning) {
        return _reading(
          SshRelayStatus.cannotStart,
          'The relay did not stay up on ${host.name}'
          '${state.lastLogLine.isEmpty ? '' : ': ${state.lastLogLine}'}. '
          'Its log is ${state.directory}/relay.log.',
          state: state,
        );
      }
    }
    if (state.token == null) return _noTokenReading(state);

    final opening = await _ports.ensureOpen(
      port,
      ruleAddedByHand: ruleAddedByHand,
    );
    if (opening.isReachable) {
      return _reading(
        SshRelayStatus.running,
        '${opening.reason} Like the session host, it does not come back by '
        'itself after ${host.name} restarts; Start brings it back at the same '
        'address.',
        state: state,
      );
    }
    return _reading(
      SshRelayStatus.unreachable,
      'The relay is running on ${host.name}. ${opening.reason}',
      state: state,
      command: opening.command,
      privileged: opening.privileged,
      outsideTheMachine: opening.outsideTheMachine,
    );
  }

  /// Stops the relay by the pid it wrote. The token stays, so a later [start]
  /// serves at the same URL and no pairing has to be redone.
  Future<SshRelayReading> stop() async {
    final state = await _inspect();
    if (state == null) return _unasked();
    if (!state.isRunning) {
      return _reading(
        SshRelayStatus.stopped,
        'No relay was running on ${host.name}.',
        state: state,
      );
    }
    if (!await _kill(state.directory)) return _wouldNotStop(state);
    return _reading(
      SshRelayStatus.stopped,
      'Stopped the relay on ${host.name}. Phones that reach this desktop '
      'through it cannot until it is started again.',
      state: state,
    );
  }

  /// [stop], then deletes the token, pid and log. The host bundle stays: the
  /// session host runs from it.
  Future<SshRelayReading> remove() async {
    final state = await _inspect();
    if (state == null) return _unasked();
    if (state.isRunning && !await _kill(state.directory)) {
      return _wouldNotStop(state);
    }
    final directory = state.directory;
    final removed = await target.run(
      'rm -f ${_q('$directory/$_pidName')} ${_q('$directory/$_tokenName')} '
      '${_q('$directory/$_logName')}',
    );
    _token = null;
    if (!removed.ok) {
      return _reading(
        SshRelayStatus.unknown,
        'The relay on ${host.name} is stopped, but its files in $directory '
        'could not be deleted (${_scrub(removed.output)}).',
      );
    }
    return _reading(
      SshRelayStatus.stopped,
      'Removed the relay from ${host.name}: its token, pid and log are gone, '
      'so its old address no longer works. The session host was left alone.',
    );
  }

  static const _pidName = 'relay.pid';
  static const _tokenName = 'relay.token';
  static const _logName = 'relay.log';

  /// Marks a process as ours: the pid in a file may have been reused.
  static const _argsMarker = ' relay --port=';

  /// One round trip: the pid, what that pid is running, the token, and the
  /// log's last line. [waitForStart] gives a relay that was just launched a
  /// few seconds to write its pid and token before anything is read.
  Future<_RelayState?> _inspect({bool waitForStart = false}) async {
    final home = _home ??= await resolveRemoteHome(target, logger: _logger);
    if (home == null) return null;
    final directory = '$home/$kRemoteHomeSubdirectory';
    final wait = waitForStart
        ? 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do '
              '[ -s "\$d/$_pidName" ] && [ -s "\$d/$_tokenName" ] && break; '
              'sleep 0.2; done; '
        : '';
    final RemoteRun result;
    try {
      result = await target.run(
        'd=${_q(directory)}; $wait'
        'p=\$(cat "\$d/$_pidName" 2>/dev/null); '
        'case "\$p" in ""|*[!0-9]*) p="";; esac; '
        'a=""; [ -n "\$p" ] && a=\$(ps -o args= -p "\$p" 2>/dev/null | head -1); '
        'echo "args=\$a"; '
        'echo "token=\$(cat "\$d/$_tokenName" 2>/dev/null)"; '
        'echo "log=\$(tail -n 1 "\$d/$_logName" 2>/dev/null)"',
      );
    } on Object catch (error) {
      _logger.debug('${host.name} could not be asked about its relay: $error');
      return null;
    }
    String field(String name) {
      for (final line in const LineSplitter().convert(result.stdout)) {
        if (line.startsWith('$name=')) {
          return line.substring(name.length + 1).trim();
        }
      }
      return '';
    }

    final args = field('args');
    final marker = args.lastIndexOf(_argsMarker);
    final token = field('token');
    // Anything else is not a token this could put in a URL.
    _token = _tokenShape.hasMatch(token) ? token : null;
    final state = _RelayState(
      directory: directory,
      runningPath: marker <= 0 ? null : _unquote(args.substring(0, marker)),
      token: _token,
      lastLogLine: _scrub(field('log')),
    );
    _logger.debug(
      'relay on ${host.name}: '
      '${state.isRunning ? 'running from ${state.runningPath}' : 'not running'}, '
      'token ${state.token == null ? 'absent' : 'present'}',
    );
    return state;
  }

  /// Starts the relay the way the session host is started — detached
  /// ([detachedStart]), out of this channel's process group. Null when it was launched; otherwise the
  /// sentence that says why not.
  Future<String?> _launch(String directory) async {
    // Asked first, because an old bundle answers `relay` with its usage and
    // exit 2, which from a detached start would only be a line in a log.
    final knows = await target.run(
      '${_q(remotePath)} relay --help >/dev/null 2>&1',
    );
    if (!knows.ok) {
      return 'The session host on ${host.name} is older than the relay command '
          '(exit ${knows.exitCode}). Deploy the session host again from this '
          'version, then start the relay.';
    }
    final started = await target.run(startCommand(directory));
    if (!started.ok) {
      return 'The relay would not start on ${host.name}: '
          '${started.output.isEmpty ? 'exit ${started.exitCode}' : _scrub(started.output)}';
    }
    return null;
  }

  /// The launch line, exposed so a test can pin it. **The token is not in it**:
  /// the box mints one into `--token-file`, because argv is world-readable.
  String startCommand(String directory) =>
      'mkdir -p ${_q(directory)} && '
      '${detachedStart('${_q(remotePath)} relay --port=$port '
      '--token-file=${_q('$directory/$_tokenName')} '
      '--pid-file=${_q('$directory/$_pidName')}', _q('$directory/$_logName'))}; '
      'echo started';

  /// Kills the pid in the pid file, and only if it is still a relay.
  Future<bool> _kill(String directory) async {
    final result = await target.run(
      'd=${_q(directory)}; p=\$(cat "\$d/$_pidName" 2>/dev/null); '
      'case "\$p" in ""|*[!0-9]*) echo karmashala-stopped; exit 0;; esac; '
      'case "\$(ps -o args= -p "\$p" 2>/dev/null)" in '
      '*"$_argsMarker"*) ;; *) rm -f "\$d/$_pidName"; echo karmashala-stopped; exit 0;; esac; '
      'kill "\$p" 2>/dev/null || true; '
      'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do '
      'kill -0 "\$p" 2>/dev/null || { rm -f "\$d/$_pidName"; echo karmashala-stopped; exit 0; }; '
      'sleep 0.2; done; echo karmashala-still-running',
    );
    return result.stdout.contains('karmashala-stopped');
  }

  Future<bool> _probeHealth(Duration within) async {
    final token = _token;
    if (token == null) return false;
    try {
      return await _probe(
        _base(token, scheme: 'http', suffix: '/$kRelayHealthPath'),
        within,
      );
    } on Object {
      // The error may quote the URL, and the URL holds the token.
      _logger.debug('the relay health check on ${host.host}:$port failed');
      return false;
    }
  }

  /// Built from [SshHost.host] — what the desktop connected with, verbatim.
  Uri _base(String token, {required String scheme, String suffix = ''}) => Uri(
    scheme: scheme,
    host: host.host,
    port: port,
    path: '/${relayAccessTokenPrefix(token)}$suffix',
  );

  SshRelayReading _reading(
    SshRelayStatus status,
    String reason, {
    _RelayState? state,
    String? command,
    PrivilegedCommand? privileged,
    bool outsideTheMachine = false,
  }) {
    final token = state?.token;
    return SshRelayReading(
      status: status,
      observedAt: _now(),
      reason: _scrub(reason),
      command: command,
      privileged: privileged,
      outsideTheMachine: outsideTheMachine,
      url: token == null ? null : _base(token, scheme: 'ws'),
      port: port,
      runningPath: state?.runningPath,
    );
  }

  SshRelayReading _unasked() => _reading(
    SshRelayStatus.unknown,
    '${host.name} did not answer `echo "\$HOME"`, so its relay could not be read.',
  );

  SshRelayReading _stoppedReading(_RelayState state) => _reading(
    SshRelayStatus.stopped,
    state.token == null
        ? 'No relay is set up on ${host.name}.'
        : 'The relay on ${host.name} is not running — stopped, or the machine '
              'restarted. Start brings it back at the same address.',
    state: state,
  );

  SshRelayReading _outdatedReading(_RelayState state) => _reading(
    SshRelayStatus.outdated,
    'The relay on ${host.name} is running from '
    '${_bundleName(state.runningPath!)}; this app deployed '
    '${_bundleName(remotePath)}. Update restarts it from the new one, at the '
    'same address.',
    state: state,
  );

  SshRelayReading _noTokenReading(_RelayState state) => _reading(
    SshRelayStatus.cannotStart,
    'The relay on ${host.name} is running but ${state.directory}/$_tokenName '
    'could not be read, so its address is unknown. Remove it and start again.',
    state: state,
  );

  SshRelayReading _wouldNotStop(_RelayState state) => _reading(
    SshRelayStatus.running,
    'The relay on ${host.name} would not stop. Nothing was deleted.',
    state: state,
    command: 'kill -9 \$(cat ${_q('${state.directory}/$_pidName')})',
  );

  /// `karmashala_host-1.2.3-linux-x64.d` out of the path it runs from — the
  /// part that names the version.
  static String _bundleName(String path) {
    for (final segment in path.split('/')) {
      if (segment.startsWith('karmashala_host-')) return segment;
    }
    return path;
  }

  /// Belt and braces: nothing here is built from the token, and if a machine's
  /// own output ever quoted it, it still would not reach a sentence or a log.
  String _scrub(String text) {
    final token = _token;
    return token == null || token.isEmpty
        ? text
        : text.replaceAll(token, '<token>');
  }

  static String _q(String value) => quoteForRemoteShell(value);

  /// `ps` prints argv joined by spaces, unquoted; a quoted form is only ever a
  /// test's. Either way the comparison is against the plain path.
  static String _unquote(String value) {
    final trimmed = value.trim();
    return trimmed.length >= 2 &&
            trimmed.startsWith("'") &&
            trimmed.endsWith("'")
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;
  }
}

class _RelayState {
  const _RelayState({
    required this.directory,
    required this.runningPath,
    required this.token,
    required this.lastLogLine,
  });

  final String directory;
  final String? runningPath;
  final String? token;
  final String lastLogLine;

  bool get isRunning => runningPath != null;
}

/// The default probe: `GET <base>/healthz` must answer 200 and say it is a
/// relay. A TCP handshake is not proof — §18's switch address completed one.
Future<bool> _httpHealthz(Uri healthz, Duration within) async {
  final client = HttpClient()..connectionTimeout = within;
  try {
    final request = await client.getUrl(healthz).timeout(within);
    final response = await request.close().timeout(within);
    final body = await response.transform(utf8.decoder).join().timeout(within);
    if (response.statusCode != 200) return false;
    final decoded = jsonDecode(body);
    return decoded is Map && decoded['status'] == 'ok';
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

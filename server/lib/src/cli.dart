import 'dart:io';

import 'package:karmashala_host_protocol/protocol.dart';
import 'pty/pty_exec.dart';
import 'pty/pty_probe.dart';
import 'relay/relay_command.dart';
import 'serve/attach_command.dart';
import 'serve/client_command.dart';
import 'serve/serve_command.dart';
import 'server/admin_commands.dart';
import 'server/init_command.dart';
import 'server/pair_command.dart';
import 'store/store_probe.dart';

const _usage =
    '''
karmashala_host $kHostVersion — Karmashala's session host.

  karmashala_host serve         own sessions on this machine until told to stop
  karmashala_host init          write a server's server.json
  karmashala_host pair          open a pairing window and print its code and QR
  karmashala_host devices       the phones paired with this server
  karmashala_host revoke <id>   revoke one (see `devices` for ids)
  karmashala_host agents        the agent CLIs this server found
  karmashala_host attach        proxy stdio to the running host's socket
  karmashala_host list          what this machine's host is holding
  karmashala_host end <id>      end one session (see `list` for ids)
  karmashala_host stop          stop the host itself
  karmashala_host relay         be the relay for one desktop
  karmashala_host probe-pty     prove the pty layer works on this machine
  karmashala_host probe-store   prove this machine can hold a store
  karmashala_host version       print the host and protocol versions

`karmashala_host <command> --help` says what a command takes.
''';

/// The flags `server.json` has, which `serve` overrides it with and `init`
/// writes it from (`ServerConfig.fromFlags`).
const _configValueFlags = {
  'name',
  'bind',
  'companion-port',
  'relay',
  'relay-token',
  'extra-relay',
  'local-relay-port',
  'mcp-port',
};
const _configSwitches = {
  'companion',
  'no-companion',
  'beacon',
  'no-beacon',
  'notes',
  'no-notes',
  'relay-enabled',
  'no-relay-enabled',
  'local-relay',
  'no-local-relay',
};

const _configFlagsUsage = '''
  --name=<n>              the name phones show (default: the hostname)
  --bind=<ip>             the phone listener's interface (default 127.0.0.1)
  --companion-port=<n>    the phone listener's port (default 47820)
  --relay=<url>           a relay phones meet this server at
  --relay-token=<t>       that relay's token (32+ url-safe characters)
  --[no-]relay-enabled    serve through --relay (default on); off keeps it
  --extra-relay=<url>     another relay, repeatable
  --[no-]local-relay      run this server's own LAN relay at --bind (default off)
  --local-relay-port=<n>  that relay's port (default 8787)
  --[no-]beacon           announce on the LAN (default off)
  --[no-]notes            phone notes (default on)
  --[no-]companion        serve phones at all (default off)
  --mcp-port=<n>          the agents' MCP endpoint, always loopback (default 47821)
''';

/// What one subcommand accepts. Checked before the command runs, so `--help`
/// or a flag nobody knows never reaches code that binds, writes or signals.
class _Command {
  const _Command({
    required this.usage,
    required this.run,
    this.valueFlags = const {},
    this.switches = const {},
    this.shortSwitches = const {},
    this.positional = 0,
  });

  final String usage;
  final Future<int> Function(
    List<String> args,
    IOSink out,
    IOSink err,
    Map<String, String> environment,
  )
  run;

  /// Written `--flag=value`.
  final Set<String> valueFlags;

  /// Written `--flag`.
  final Set<String> switches;

  /// Written `-f`.
  final Set<String> shortSwitches;

  /// How many bare words may follow the command.
  final int positional;

  /// Null when [args] are all known, else the sentence to refuse with.
  String? refusal(List<String> args) {
    var words = 0;
    for (final arg in args) {
      if (arg.startsWith('--')) {
        final equals = arg.indexOf('=');
        final name = arg.substring(2, equals < 0 ? arg.length : equals);
        if (equals < 0 && switches.contains(name)) continue;
        if (equals >= 0 && valueFlags.contains(name)) continue;
        if (valueFlags.contains(name)) {
          return '--$name needs a value: --$name=…';
        }
        if (switches.contains(name)) return '--$name takes no value';
        return 'unknown flag "$arg"';
      }
      if (arg.startsWith('-') && arg.length > 1) {
        if (shortSwitches.contains(arg.substring(1))) continue;
        return 'unknown flag "$arg"';
      }
      words++;
      if (words > positional) return 'unexpected argument "$arg"';
    }
    return null;
  }
}

final Map<String, _Command> _commands = {
  'serve': _Command(
    usage:
        '''
karmashala_host serve — own sessions on this machine until told to stop.

  --data-dir=<dir>        the server's data (default ~/.karmashala, the
                          folder the desktop app opens too):
                          <dir>/karmashala.sqlite (the store, created and
                          migrated here) and <dir>/server.json (its config)
$_configFlagsUsage
Each config flag overrides server.json, field by field, for the life of the
process. The agent CLIs on this machine are looked for at start.
''',
    valueFlags: {'data-dir', ..._configValueFlags},
    switches: _configSwitches,
    run: (args, out, err, env) =>
        runServe(args, out: out, err: err, environment: env),
  ),
  'init': _Command(
    usage: '''
karmashala_host init — write a server's server.json (owner-only).

  --data-dir=<dir>        where (default ~/.karmashala)
  --force                 replace a server.json that is there
$_configFlagsUsage''',
    valueFlags: {'data-dir', ..._configValueFlags},
    switches: {'force', ..._configSwitches},
    run: (args, out, err, env) =>
        runInit(args, out: out, err: err, environment: env),
  ),
  'pair': _Command(
    usage: '''
karmashala_host pair — open a pairing window at the running server and print
its code and QR, then wait until a device pairs or the window closes.

  --capabilities=<list|all>   what the device may do (default all)
  --relay=<url>               meet the phone at this relay, for this window
  --name=<label>              the name the paired device gets
  --address=<host[:port]>     where the phone dials (makes the QR a host invite)
  --no-color                  draw the QR without colour
''',
    valueFlags: {'capabilities', 'relay', 'name', 'address'},
    switches: {'no-color'},
    run: (args, out, err, env) =>
        runPair(args, out: out, err: err, environment: env),
  ),
  'devices': _Command(
    usage: '''
karmashala_host devices — every phone paired with the running server.
''',
    run: (args, out, err, env) =>
        runDevices(args, out: out, err: err, environment: env),
  ),
  'revoke': _Command(
    usage: '''
karmashala_host revoke <id> — revoke one paired device, by its id or a prefix
only it has (see `devices`), and drop its live links.
''',
    positional: 1,
    run: (args, out, err, env) =>
        runRevoke(args, out: out, err: err, environment: env),
  ),
  'agents': _Command(
    usage: '''
karmashala_host agents — the agent CLIs the running server recorded.

  --refresh               look for them again now
''',
    switches: {'refresh'},
    run: (args, out, err, env) =>
        runAgents(args, out: out, err: err, environment: env),
  ),
  'attach': _Command(
    usage: '''
karmashala_host attach — proxy stdio to the running host's socket.
''',
    run: (args, out, err, env) =>
        runAttach(args, output: out, err: err, environment: env),
  ),
  'list': _Command(
    usage: '''
karmashala_host list — every session this machine's host is holding.
''',
    run: (args, out, err, env) => runList(out: out, err: err, environment: env),
  ),
  'end': _Command(
    usage: '''
karmashala_host end <id> — end one session (see `list` for ids).
''',
    positional: 1,
    run: (args, out, err, env) =>
        runEnd(args, out: out, err: err, environment: env),
  ),
  'stop': _Command(
    usage: '''
karmashala_host stop — stop the host itself. Refuses while it holds running
sessions.

  --force, -f             stop it anyway, and its sessions with it
''',
    switches: {'force'},
    shortSwitches: {'f'},
    run: (args, out, err, env) =>
        runStop(args, out: out, err: err, environment: env),
  ),
  'probe-pty': _Command(
    usage: '''
karmashala_host probe-pty — prove the pty layer works on this machine.
''',
    run: (args, out, err, env) => runPtyProbe(out: out),
  ),
  'probe-store': _Command(
    usage: '''
karmashala_host probe-store — prove this machine can hold a store.
''',
    run: (args, out, err, env) => runStoreProbe(out: out),
  ),
  'version': _Command(
    usage: '''
karmashala_host version — print the host and protocol versions.
''',
    run: (args, out, err, env) async {
      // Both numbers, because the deployer compares them separately: a host
      // can be new enough to run and still speak a protocol the app does not.
      out.writeln('host $kHostVersion protocol $kProtocolVersion');
      return 0;
    },
  ),
};

/// Runs one `karmashala_host` command. [environment] is where the user's
/// home, runtime dir and host directory are read from whenever a command is
/// not told its data or host directory outright: only the executable passes
/// `Platform.environment`, so nothing in this library — or a test calling it
/// — ever falls back to the real home by itself.
Future<int> runHostCli(
  List<String> args, {
  required Map<String, String> environment,
  IOSink? out,
  IOSink? err,
}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final name = args.isEmpty ? '' : args.first;
  final rest = args.skip(1).toList();
  switch (name) {
    case 'relay':
      // Its own strict parser, which answers --help and refuses the unknown.
      return runRelay(rest, out: sink, err: errSink);
    case 'pty-exec':
      // Not in the usage: the host starts it, nobody else has a reason to.
      // What follows is a child's argv, never flags of ours.
      return runPtyExec(rest);
    case '':
    case '-h':
    case '--help':
      sink.write(_usage);
      return args.isEmpty ? 2 : 0;
  }
  final command = _commands[name];
  if (command == null) {
    errSink
      ..writeln('karmashala_host: unknown command "$name"')
      ..write(_usage);
    return 2;
  }
  if (rest.contains('--help') || rest.contains('-h')) {
    sink.write(command.usage);
    return 0;
  }
  final refused = command.refusal(rest);
  if (refused != null) {
    errSink
      ..writeln('karmashala_host $name: $refused')
      ..write(command.usage);
    return 2;
  }
  return command.run(rest, sink, errSink, environment);
}

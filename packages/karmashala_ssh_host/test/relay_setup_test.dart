import 'dart:typed_data';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh_host/host.dart';
import 'package:test/test.dart';

const _token = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const _home = '/home/dlohani';
const _dir = '$_home/.karmashala';
const _current =
    '$_dir/bin/karmashala_host-1.4.0-linux-x64.d/bin/karmashala_host';
const _older =
    '$_dir/bin/karmashala_host-1.3.0-linux-x64.d/bin/karmashala_host';

/// A box with a relay's three files and one process, scripted by what each
/// command is rather than by its position, so a test reads as a situation.
class _Box implements HostDeployTarget {
  /// The executable the relay is running from; null is not running.
  String? runningFrom;
  String? token;
  String lastLog = '';

  /// What `relay --help` exits with: 2 is a bundle older than the command.
  int helpExit = 0;

  /// Whether a launched relay stays up.
  bool launches = true;
  bool stops = true;
  String firewall = 'none';
  String home = _home;

  final commands = <String>[];

  @override
  String get address => 'dlohani@203.0.113.9:22';

  List<String> get launchesRun =>
      commands.where((c) => c.contains('setsid nohup')).toList();

  @override
  Future<RemoteRun> run(String command) async {
    commands.add(command);
    if (command == 'echo "\$HOME"') return RemoteRun(0, '$home\n', '');
    if (command.endsWith('relay --help >/dev/null 2>&1')) {
      return RemoteRun(helpExit, '', '');
    }
    if (command.contains('setsid nohup')) {
      if (launches) {
        runningFrom = RegExp(
          r"setsid nohup '([^']+)' relay",
        ).firstMatch(command)!.group(1);
        token ??= _token;
      }
      return const RemoteRun(0, 'started\n', '');
    }
    if (command.contains('kill "\$p"')) {
      if (runningFrom != null && !stops) {
        return const RemoteRun(0, 'karmashala-still-running\n', '');
      }
      runningFrom = null;
      return const RemoteRun(0, 'karmashala-stopped\n', '');
    }
    if (command.startsWith('rm -f ')) {
      token = null;
      return const RemoteRun(0, '', '');
    }
    if (command.contains('ps -o args=')) {
      final args = runningFrom == null
          ? ''
          : '$runningFrom relay --port=8787 --token-file=$_dir/relay.token '
                '--pid-file=$_dir/relay.pid';
      return RemoteRun(
        0,
        'args=$args\ntoken=${token ?? ''}\nlog=$lastLog\n',
        '',
      );
    }
    if (command.contains('has ufw')) {
      return RemoteRun(0, '$firewall\n', '');
    }
    throw StateError('unscripted: $command');
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async =>
      throw StateError('the relay uploads nothing: the bundle is the host\'s');

  @override
  Future<RemoteChannel> exec(String command) => throw UnimplementedError();
}

class _Log implements AppLogger {
  final lines = <String>[];

  @override
  void debug(String message) => lines.add(message);

  @override
  void info(String message) => lines.add(message);

  @override
  void warning(String message, [Object? error, StackTrace? stackTrace]) =>
      lines.add('$message $error');

  @override
  void error(String message, [Object? error, StackTrace? stackTrace]) =>
      lines.add('$message $error');
}

void main() {
  final host = SshHost(
    id: 'h1',
    name: 'do-box',
    host: 'box.example.com',
    port: 22,
    username: 'dlohani',
    authMethod: SshAuthMethod.privateKey,
    createdAt: DateTime.utc(2026, 9, 17),
  );

  late _Box box;
  late _Log log;
  late List<bool> probeAnswers;
  late List<Uri> probed;

  setUp(() {
    box = _Box();
    log = _Log();
    probeAnswers = [true];
    probed = [];
  });

  SshRelaySetup setup({
    String remotePath = _current,
    int port = kDefaultSshRelayPort,
  }) => SshRelaySetup(
    host: host,
    target: box,
    remotePath: remotePath,
    port: port,
    clock: () => DateTime.utc(2026, 9, 17, 12),
    logger: log,
    probe: (healthz, _) async {
      probed.add(healthz);
      return probeAnswers.length > 1
          ? probeAnswers.removeAt(0)
          : probeAnswers.first;
    },
  );

  /// Everything a reading or a log could have said, for the token assertions.
  String everythingSaid(SshRelayReading reading) => [
    reading.reason,
    reading.command ?? '',
    '$reading',
    ...log.lines,
  ].join('\n');

  test('nothing set up reads as stopped, and nothing is changed', () async {
    final reading = await setup().check();

    expect(reading.status, SshRelayStatus.stopped);
    expect(reading.reason, contains('No relay is set up on do-box'));
    expect(reading.url, isNull);
    expect(reading.isServing, isFalse);
    expect(box.launchesRun, isEmpty);
    expect(probed, isEmpty, reason: 'nothing to dial');
  });

  test(
    'the launch line is the host\'s own supervision, with no token in it',
    () async {
      final line = setup().startCommand(_dir);

      expect(
        line,
        "mkdir -p '$_dir' && "
        'if command -v setsid >/dev/null 2>&1; then '
        "setsid nohup '$_current' relay --port=8787 "
        "--token-file='$_dir/relay.token' --pid-file='$_dir/relay.pid' "
        ">> '$_dir/relay.log' 2>&1 < /dev/null & "
        'else '
        "nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' "
        "'$_current' relay --port=8787 "
        "--token-file='$_dir/relay.token' --pid-file='$_dir/relay.pid' "
        ">> '$_dir/relay.log' 2>&1 < /dev/null & "
        'fi; echo started',
      );
      expect(line, isNot(contains('--token=')));

      await setup().start();
      expect(box.launchesRun.single, line);
      expect(box.commands.join('\n'), isNot(contains(_token)));
    },
  );

  test('a home with a quote in it is quoted, not trusted', () async {
    box.home = "/home/o'brien";
    final line = setup().startCommand("/home/o'brien/.karmashala");
    expect(line, contains(r"mkdir -p '/home/o'\''brien/.karmashala'"));
  });

  test('the executable and the port are the caller\'s', () async {
    final reading = await setup(remotePath: _older, port: 9001).start();

    expect(
      box.launchesRun.single,
      contains("setsid nohup '$_older' relay --port=9001 "),
    );
    expect(reading.port, 9001);
    expect(reading.url!.port, 9001);
  });

  test('a start that already answers opens nothing', () async {
    final reading = await setup().start();

    expect(reading.status, SshRelayStatus.running);
    expect(reading.isServing, isTrue);
    expect(reading.runningPath, _current);
    expect(reading.reason, contains('does not come back by itself'));
    expect(box.commands.where((c) => c.contains('ufw')), isEmpty);
    // The address the desktop connected with, verbatim — not the target's
    // `user@host:22`, and nothing the box said about itself.
    expect(reading.url, Uri.parse('ws://box.example.com:8787/k/$_token'));
    expect(
      probed.single,
      Uri.parse('http://box.example.com:8787/k/$_token/healthz'),
    );
  });

  test(
    'a shut port is opened only after the probe fails, then proved',
    () async {
      probeAnswers = [false, true];
      box.firewall = 'ufw';

      final reading = await setup().start();

      expect(reading.status, SshRelayStatus.running);
      expect(reading.reason, contains('ufw'));
      expect(
        probed,
        hasLength(2),
        reason: 'running is a claim about the second probe',
      );
      final order = box.commands;
      expect(
        order.indexWhere((c) => c.contains('has ufw')),
        greaterThan(order.indexWhere((c) => c.contains('setsid nohup'))),
      );
    },
  );

  test('a rule that went in while it stayed shut names the provider', () async {
    probeAnswers = [false];
    box.firewall = 'ufw';

    final reading = await setup().start();

    expect(reading.status, SshRelayStatus.unreachable);
    expect(reading.reason, contains('provider'));
    expect(
      reading.url,
      isNotNull,
      reason: 'the address is right; the path to it is not',
    );
    expect(reading.isServing, isFalse);
  });

  test('no sudo surfaces the command to run by hand', () async {
    probeAnswers = [false];
    box.firewall = 'nosudo-ufw';

    final reading = await setup().start();

    expect(reading.status, SshRelayStatus.unreachable);
    expect(reading.command, contains('sudo ufw allow 8787/tcp'));
    // The terminal step, with what it does and why — and never the token.
    expect(reading.privileged?.command, 'sudo ufw allow 8787/tcp');
    expect(reading.privileged?.why, contains('password'));
    expect(
      '${reading.privileged?.command} ${reading.privileged?.does} '
      '${reading.privileged?.why} ${everythingSaid(reading)}',
      isNot(contains(_token)),
    );
  });

  test('checking again after the command was run blames the provider, not '
      'sudo', () async {
    box
      ..runningFrom = _current
      ..token = _token;
    probeAnswers = [false];
    box.firewall = 'nosudo-ufw';

    final reading = await setup().start(ruleAddedByHand: true);

    expect(reading.status, SshRelayStatus.unreachable);
    expect(reading.privileged, isNull);
    expect(reading.outsideTheMachine, isTrue);
    expect(reading.reason, contains('DigitalOcean'));
    expect(everythingSaid(reading), isNot(contains(_token)));
  });

  test('checking again after the command was run finds it open', () async {
    box
      ..runningFrom = _current
      ..token = _token;
    probeAnswers = [true];
    box.firewall = 'nosudo-ufw';

    final reading = await setup().start(ruleAddedByHand: true);

    expect(reading.status, SshRelayStatus.running);
    expect(box.commands.where((c) => c.contains('has ufw')), isEmpty);
  });

  test(
    'a relay from another version is outdated, and start updates it',
    () async {
      box
        ..runningFrom = _older
        ..token = _token;

      final before = await setup().check();
      expect(before.status, SshRelayStatus.outdated);
      expect(before.reason, contains('karmashala_host-1.3.0-linux-x64.d'));
      expect(before.reason, contains('karmashala_host-1.4.0-linux-x64.d'));
      expect(before.url, isNotNull);

      final after = await setup().start();
      expect(after.status, SshRelayStatus.running);
      expect(after.runningPath, _current);
      // Same token file, so the same URL: no pairing is redone by an update.
      expect(after.url, before.url);
      final order = box.commands;
      expect(
        order.indexWhere((c) => c.contains('kill "\$p"')),
        lessThan(order.indexWhere((c) => c.contains('setsid nohup'))),
      );
    },
  );

  test('running and current is only proved, never restarted', () async {
    box
      ..runningFrom = _current
      ..token = _token;

    final reading = await setup().start();

    expect(reading.status, SshRelayStatus.running);
    expect(box.launchesRun, isEmpty);
    expect(box.commands.where((c) => c.contains('kill')), isEmpty);
  });

  test(
    'check on a running relay that does not answer changes nothing',
    () async {
      box
        ..runningFrom = _current
        ..token = _token;
      probeAnswers = [false];

      final reading = await setup().check();

      expect(reading.status, SshRelayStatus.unreachable);
      expect(box.commands.where((c) => c.contains('ufw')), isEmpty);
      expect(box.launchesRun, isEmpty);
    },
  );

  test(
    'a bundle older than the relay command cannot start, and says how',
    () async {
      box.helpExit = 2;

      final reading = await setup().start();

      expect(reading.status, SshRelayStatus.cannotStart);
      expect(reading.reason, contains('Deploy the session host again'));
      expect(box.launchesRun, isEmpty);
    },
  );

  test('a relay that does not stay up quotes its log', () async {
    box
      ..launches = false
      ..lastLog =
          'karmashala_host: port 8787 is not free (Address already in use).';

    final reading = await setup().start();

    expect(reading.status, SshRelayStatus.cannotStart);
    expect(reading.reason, contains('port 8787 is not free'));
    expect(reading.reason, contains('$_dir/relay.log'));
  });

  test('stop kills by the pid file and keeps the token', () async {
    box
      ..runningFrom = _current
      ..token = _token;

    final reading = await setup().stop();

    expect(reading.status, SshRelayStatus.stopped);
    expect(box.runningFrom, isNull);
    expect(box.token, _token, reason: 'a later start serves at the same URL');
    expect(box.commands.where((c) => c.startsWith('rm -f ')), isEmpty);
  });

  test(
    'a relay that will not stop is said to be running, and nothing is deleted',
    () async {
      box
        ..runningFrom = _current
        ..token = _token
        ..stops = false;

      final reading = await setup().remove();

      expect(reading.status, SshRelayStatus.running);
      expect(reading.command, contains('kill -9'));
      expect(box.token, _token);
    },
  );

  test('remove stops it and deletes exactly its three files', () async {
    box
      ..runningFrom = _current
      ..token = _token;

    final reading = await setup().remove();

    expect(reading.status, SshRelayStatus.stopped);
    expect(reading.url, isNull);
    expect(
      box.commands.singleWhere((c) => c.startsWith('rm -f ')),
      "rm -f '$_dir/relay.pid' '$_dir/relay.token' '$_dir/relay.log'",
    );
    expect(reading.reason, contains('session host was left alone'));
  });

  test('a machine that will not say where home is reads as unknown', () async {
    box.home = '';

    final reading = await setup().start();

    expect(reading.status, SshRelayStatus.unknown);
    expect(box.launchesRun, isEmpty);
  });

  test(
    'the token is in the url and nowhere a person or a log would read',
    () async {
      box.lastLog = 'something quoted $_token by mistake';
      probeAnswers = [false];
      box.firewall = 'ufw';

      final started = await setup().start();
      expect(started.url.toString(), contains(_token));
      expect(everythingSaid(started), isNot(contains(_token)));

      box.launches = false;
      box.runningFrom = null;
      final failed = await setup().start();
      expect(failed.status, SshRelayStatus.cannotStart);
      expect(everythingSaid(failed), isNot(contains(_token)));

      expect(everythingSaid(await setup().check()), isNot(contains(_token)));
      expect(everythingSaid(await setup().remove()), isNot(contains(_token)));
    },
  );

  test('a token file holding something else is not put in a url', () async {
    box
      ..runningFrom = _current
      ..token = 'not a token';

    final reading = await setup().check();

    expect(reading.status, SshRelayStatus.cannotStart);
    expect(reading.url, isNull);
  });
}

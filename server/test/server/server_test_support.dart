import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/karmashala_host.dart';

/// An [IOSink] that keeps what it was given and completes [seen] for each
/// phrase once it has been written.
class CapturingSink implements IOSink {
  final StringBuffer text = StringBuffer();
  final _waiting = <String, Completer<void>>{};

  /// Completes once [phrase] has been written.
  Future<void> saw(String phrase) {
    if (text.toString().contains(phrase)) return Future.value();
    return (_waiting[phrase] ??= Completer<void>()).future;
  }

  void _check() {
    final now = text.toString();
    for (final entry in _waiting.entries.toList()) {
      if (now.contains(entry.key) && !entry.value.isCompleted) {
        entry.value.complete();
        _waiting.remove(entry.key);
      }
    }
  }

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? object) {
    text.write(object);
    _check();
  }

  @override
  void writeln([Object? object = '']) {
    text.writeln(object);
    _check();
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    text.writeAll(objects, separator);
    _check();
  }

  @override
  void writeCharCode(int charCode) => text.writeCharCode(charCode);

  @override
  void add(List<int> data) => write(utf8.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}
}

/// A `serve` running in this process on temp directories, until [stop].
class InProcessServer {
  InProcessServer._(this.paths, this.out, this.err, this._stop, this.exited);

  final HostPaths paths;
  final CapturingSink out;
  final CapturingSink err;
  final Completer<void> _stop;

  /// Completes with `serve`'s exit code.
  final Future<int> exited;

  /// The port the phone listener bound, as the greeting says it.
  int get companionPort {
    final match = RegExp(
      r'companion on port (\d+)',
    ).firstMatch(out.text.toString());
    if (match == null) {
      throw StateError('not serving phones:\n$out\n${err.text}');
    }
    return int.parse(match.group(1)!);
  }

  /// Starts `serve` with [args] and waits for its greeting. Throws with what
  /// it said if it exits first.
  static Future<InProcessServer> start(
    Directory root,
    List<String> args, {
    ServerAgents Function(DataService data)? agentsFor,
  }) async {
    final paths = HostPaths(Directory('${root.path}/host'));
    final out = CapturingSink();
    final err = CapturingSink();
    final stop = Completer<void>();
    final exited = runServe(
      args,
      // A home of its own: without --data-dir in [args], it is where the
      // data folder resolves — never the owner's.
      environment: scratchEnvironment(root),
      agentScanDelay: Duration.zero,
      out: out,
      err: err,
      paths: paths,
      until: stop.future,
      agentsFor: agentsFor ?? noAgents,
    );
    await Future.any([
      out.saw('restored '),
      exited.then(
        (code) =>
            throw StateError('serve exited $code:\n${out.text}\n${err.text}'),
      ),
    ]);
    return InProcessServer._(paths, out, err, stop, exited);
  }

  Future<int> stop() {
    if (!_stop.isCompleted) _stop.complete();
    return exited;
  }
}

/// An environment whose home and host directory are nowhere real: for a
/// command a test runs that must refuse, or print, before touching anything.
/// The library never falls back to the real environment, so every call names
/// one — this, a temp home, or `--data-dir` and paths outright.
const Map<String, String> kNowhereEnvironment = {
  'HOME': '/nonexistent/karmashala-test-home',
  'USERPROFILE': '/nonexistent/karmashala-test-home',
  'KARMASHALA_HOST_DIR': '/nonexistent/karmashala-test-home/host',
};

/// A home under [root] — a test's temp directory — and its host directory,
/// as the environment a command resolves them from.
Map<String, String> scratchEnvironment(Directory root) => {
  'HOME': '${root.path}/home',
  'USERPROFILE': '${root.path}/home',
  'KARMASHALA_HOST_DIR': '${root.path}/host',
  // Agent work only when asked: no usage schedule reaching for a Keychain,
  // no start-up probe of this machine's CLIs.
  'KARMASHALA_AGENT_WORK': 'off',
  // No WSL hook spool drained: the owner's distributions write theirs.
  'KARMASHALA_HOOK_SPOOLS': 'off',
};

/// A [ServerAgents] whose probe finds nothing and spawns nothing.
ServerAgents noAgents(DataService data) =>
    ServerAgents(data: data, runner: FakeRunner(const {}));

/// Answers `command -v <name>` for each name in [located] with its path,
/// `<path> <version arguments>` with `9.9.9`, and everything else with a
/// failure — no process is started.
class FakeRunner implements CommandRunner {
  FakeRunner(this.located);

  final Map<String, String> located;
  final asked = <CommandRequest>[];

  @override
  String get environmentId => localHostEnvironmentId;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    asked.add(request);
    final script = request.arguments.join(' ');
    for (final entry in located.entries) {
      if (script.contains('command -v ${entry.key}')) {
        final marked = request.arguments.contains('-ilc')
            ? '__karmashala_agent:${entry.value}'
            : entry.value;
        return CommandResult(exitCode: 0, stdout: '$marked\n', stderr: '');
      }
      if (request.executable == entry.value) {
        return const CommandResult(exitCode: 0, stdout: '9.9.9\n', stderr: '');
      }
    }
    return const CommandResult(exitCode: 1, stdout: '', stderr: 'not found');
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) =>
      throw UnsupportedError('the fake runs nothing');
}

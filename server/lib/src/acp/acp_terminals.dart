import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show File;

import 'package:agent_cli/process.dart'
    show
        CommandRequest,
        CommandResult,
        CommandRunner,
        EnvironmentPath,
        ProcessHandle,
        kProbeTimeout;
import 'package:path/path.dart' as p;
import 'package:karmashala_acp/karmashala_acp.dart'
    show AcpMethods, AcpRpcError, JsonMap, JsonMapReads, JsonRpcErrorCodes;

import 'acp_path_scope.dart';

/// The most output one terminal keeps, whatever the agent asks for.
const int kAcpTerminalMaxBytes = 1024 * 1024;

/// How much of a released terminal's output is kept, for the chat to show.
const int kAcpReleasedTerminalBytes = 64 * 1024;

/// The variable a Windows `cmd.exe` terminal reads its command line from.
const String kAcpTerminalCommandVariable = 'KARMASHALA_TERMINAL_COMMAND';

/// Git Bash's `sh` on the machine [runner] reaches: Git found by name, as
/// every other git call here finds it, then `bin\sh.exe` above it — which is
/// the shell Claude Code's own Bash tool runs on Windows. Null without one.
Future<String?> findGitShell(CommandRunner runner) async {
  final CommandResult found;
  try {
    found = await runner.run(
      const CommandRequest(
        executable: 'where',
        arguments: ['git'],
        timeout: kProbeTimeout,
      ),
    );
  } on Object {
    return null;
  }
  if (!found.ok) return null;
  for (final line in const LineSplitter().convert(found.stdout)) {
    var dir = p.windows.dirname(line.trim());
    // `Git\cmd\git.exe`, or `Git\mingw64\bin\git.exe`.
    for (var up = 0; up < 3 && dir.isNotEmpty; up++) {
      dir = p.windows.dirname(dir);
      final sh = p.windows.join(dir, 'bin', 'sh.exe');
      if (File(sh).existsSync()) return sh;
    }
  }
  return null;
}

/// A terminal's output as last read: what [AcpTerminals.snapshot] answers.
typedef AcpTerminalSnapshot = ({String output, bool truncated, int? exitCode});

/// **The `terminal/*` an ACP agent asks of this client**: each command run on
/// the session's machine through its own runner, in the session's folder,
/// its output bounded, and every one killed when [releaseAll] ends them.
class AcpTerminals {
  AcpTerminals({
    required this.start,
    required this.scope,
    required this.environmentId,
    required this.posix,
    Future<String?> Function()? gitShell,
    this.maxBytes = kAcpTerminalMaxBytes,
  }) : _gitShell = gitShell ?? _noGitShell;

  final Future<ProcessHandle> Function(CommandRequest request) start;

  /// Where a `cwd` may be: the session's folder.
  final AcpPathScope scope;
  final String environmentId;

  /// Whether a bare command line runs through `sh -c`; else, on Windows,
  /// Git Bash's `sh` when [_gitShell] finds one, and `cmd.exe` when not.
  final bool posix;
  final int maxBytes;

  /// Git Bash's `sh` on a Windows machine, or null; asked once.
  final Future<String?> Function() _gitShell;
  Future<String?>? _gitShellFound;

  static Future<String?> _noGitShell() async => null;

  /// Told the terminal's id each time its output or its exit moves.
  void Function(String terminalId)? onOutput;

  final _live = <String, _Terminal>{};
  final _released = <String, AcpTerminalSnapshot>{};
  var _ids = 0;
  var _closed = false;

  /// [terminalId]'s output now, live or released; null for one never made.
  AcpTerminalSnapshot? snapshot(String terminalId) =>
      _live[terminalId]?.snapshot ?? _released[terminalId];

  /// Answers one `terminal/*` request.
  Future<Object?> handle(String method, JsonMap params) => switch (method) {
    AcpMethods.terminalCreate => _create(params),
    AcpMethods.terminalOutput => _output(params),
    AcpMethods.terminalWaitForExit => _waitForExit(params),
    AcpMethods.terminalKill => _kill(params),
    AcpMethods.terminalRelease => _release(params),
    _ => throw AcpRpcError(
      JsonRpcErrorCodes.methodNotFound,
      'Method not found: $method',
    ),
  };

  /// Kills every terminal still running and forgets them: the session ended.
  Future<void> releaseAll() async {
    _closed = true;
    final live = [..._live.keys];
    await Future.wait([for (final id in live) _drop(id)]);
  }

  Future<JsonMap> _create(JsonMap params) async {
    if (_closed) {
      throw AcpRpcError(
        JsonRpcErrorCodes.internalError,
        'this session has ended, so no command can be started',
      );
    }
    final command = params.requireString('command');
    if (command.trim().isEmpty) {
      throw AcpRpcError(JsonRpcErrorCodes.invalidParams, 'no command given');
    }
    final args = params.strings('args') ?? const <String>[];
    final cwd = scope.resolve(
      params.string('cwd') ?? scope.root,
      verb: 'used as a working directory',
    );
    final env = <String, String>{
      for (final variable in params.objects('env') ?? const <JsonMap>[])
        if (variable.string('name') case final name? when name.isNotEmpty)
          name: variable.string('value') ?? '',
    };
    final asked = params.integer('outputByteLimit');
    final limit = asked == null || asked <= 0 || asked > maxBytes
        ? maxBytes
        : asked;
    final ProcessHandle process;
    try {
      process = await start(
        await _request(
          command,
          args,
          EnvironmentPath(environmentId: environmentId, path: cwd.agent),
          env,
        ),
      );
    } on Object catch (error) {
      throw AcpRpcError(
        JsonRpcErrorCodes.internalError,
        'could not start $command: $error',
      );
    }
    final id = 'term-${++_ids}';
    _live[id] = _Terminal(process, _Output(limit), () => onOutput?.call(id));
    return {'terminalId': id};
  }

  /// A command with its arguments runs as given; a bare command line goes to
  /// the shell an agent's own shell tool uses there, which is what an agent
  /// writing `npm ci && npm test` means.
  Future<CommandRequest> _request(
    String command,
    List<String> args,
    EnvironmentPath cwd,
    Map<String, String> env,
  ) async {
    CommandRequest request(String executable, List<String> arguments) =>
        CommandRequest(
          executable: executable,
          arguments: arguments,
          workingDirectory: cwd,
          environment: env,
        );
    if (args.isNotEmpty || !command.contains(RegExp(r'\s'))) {
      return request(command, args);
    }
    if (posix) return request('sh', ['-c', command]);
    final sh = await (_gitShellFound ??= _gitShell());
    if (sh != null) return request(sh, ['-c', command]);
    // cmd expands the variable before it parses `&&` or quotes, and no
    // Windows argument quoting stands between the line and cmd.
    return CommandRequest(
      executable: 'cmd.exe',
      arguments: const ['/d', '/c', '%$kAcpTerminalCommandVariable%'],
      workingDirectory: cwd,
      environment: {...env, kAcpTerminalCommandVariable: command},
    );
  }

  Future<JsonMap> _output(JsonMap params) async {
    final id = params.requireString('terminalId');
    final terminal = _live[id];
    final released = _released[id];
    if (terminal == null && released == null) throw _unknown(id);
    final (:output, :truncated, :exitCode) = terminal?.snapshot ?? released!;
    return {
      'output': output,
      'truncated': truncated,
      if (terminal == null || terminal.exited)
        'exitStatus': {'exitCode': exitCode, 'signal': null},
    };
  }

  Future<JsonMap> _waitForExit(JsonMap params) async {
    final id = params.requireString('terminalId');
    final terminal = _live[id];
    if (terminal == null) {
      final released = _released[id];
      if (released == null) throw _unknown(id);
      return {'exitCode': released.exitCode, 'signal': null};
    }
    final code = await terminal.finished;
    return {'exitCode': code, 'signal': null};
  }

  Future<JsonMap> _kill(JsonMap params) async {
    final id = params.requireString('terminalId');
    final terminal = _live[id] ?? (throw _unknown(id));
    await terminal.kill();
    return const {};
  }

  Future<JsonMap> _release(JsonMap params) async {
    final id = params.requireString('terminalId');
    if (!_live.containsKey(id)) throw _unknown(id);
    await _drop(id);
    return const {};
  }

  Future<void> _drop(String id) async {
    final terminal = _live[id];
    if (terminal == null) return;
    await terminal.kill();
    _live.remove(id);
    final (:output, :truncated, :exitCode) = terminal.snapshot;
    final kept = _Output(kAcpReleasedTerminalBytes)..add(output);
    _released[id] = (
      output: kept.text,
      truncated: truncated || kept.truncated,
      exitCode: exitCode,
    );
    while (_released.length > 50) {
      _released.remove(_released.keys.first);
    }
    onOutput?.call(id);
  }

  static AcpRpcError _unknown(String id) => AcpRpcError(
    JsonRpcErrorCodes.invalidParams,
    'no terminal $id in this session (it was never created, or was released)',
  );
}

class _Terminal {
  _Terminal(this.process, this.output, this.changed) {
    final streams = [
      process.stdoutLines.listen(_line, onError: (Object _) {}),
      process.stderrLines.listen(_line, onError: (Object _) {}),
    ];
    final drained = Future.wait([
      for (final s in streams) s.asFuture<void>(),
    ]).catchError((Object _) => const <void>[]);
    finished = process.exitCode.then(
      (code) async {
        // The last lines can trail the exit; never wait on them for ever.
        await drained.timeout(const Duration(seconds: 2), onTimeout: () => []);
        exitCode = code;
        changed();
        return code;
      },
      onError: (Object _) {
        exitCode = -1;
        changed();
        return -1;
      },
    );
  }

  final ProcessHandle process;
  final _Output output;
  final void Function() changed;
  late final Future<int> finished;
  int? exitCode;

  bool get exited => exitCode != null;

  AcpTerminalSnapshot get snapshot =>
      (output: output.text, truncated: output.truncated, exitCode: exitCode);

  void _line(String line) {
    output.add(output.isEmpty ? line : '\n$line');
    changed();
  }

  Future<void> kill() async {
    if (exited) return;
    try {
      await process.kill();
    } on Object {
      // Gone already.
    }
    await finished.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  }
}

/// Output kept within [limit] bytes, the earliest dropped first and cut on a
/// UTF-8 character boundary.
class _Output {
  _Output(this.limit);

  final int limit;
  final _chunks = Queue<List<int>>();
  var _bytes = 0;
  var truncated = false;

  bool get isEmpty => _bytes == 0 && !truncated;

  void add(String text) {
    final bytes = utf8.encode(text);
    if (bytes.isEmpty) return;
    _chunks.add(bytes);
    _bytes += bytes.length;
    while (_bytes > limit && _chunks.isNotEmpty) {
      truncated = true;
      final first = _chunks.removeFirst();
      final over = _bytes - limit;
      if (first.length <= over) {
        _bytes -= first.length;
        continue;
      }
      var cut = over;
      while (cut < first.length && (first[cut] & 0xC0) == 0x80) {
        cut++;
      }
      _bytes -= cut;
      if (cut < first.length) _chunks.addFirst(first.sublist(cut));
    }
  }

  String get text => utf8.decode([
    for (final chunk in _chunks) ...chunk,
  ], allowMalformed: true);
}

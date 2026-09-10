import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'launcher_mcp.dart';

/// What a probe of the stdio bridge found.
///
/// Four outcomes, because they need four different responses from the user. The
/// panel that used to report this had two — the file is there, or it is not —
/// which is why it spent an hour on 2026-09-03 saying *Tools available* while
/// every agent session on the machine had lost every Karmashala tool.
enum McpBridgeVerdict {
  /// Spawned, and completed an MCP `initialize` handshake.
  answering,

  /// On disk, but the process would not start — WSL's interop handler had gone,
  /// so `posix_spawn` of any Windows executable returned `ENOEXEC`.
  unspawnable,

  /// Nothing beside the app to spawn.
  absent,

  /// Started, then did not complete the handshake — no reply, a reply that was
  /// not MCP, or an exit before answering.
  noHandshake,
}

/// The outcome of one probe, with the evidence behind it.
class McpBridgeProbeResult {
  const McpBridgeProbeResult({
    required this.verdict,
    required this.took,
    this.path,
    this.detail,
  });

  final McpBridgeVerdict verdict;

  /// How long the probe took, spawn included. Worth showing: this is the cost
  /// of asking, and it is why the check does not run on a timer.
  final Duration took;

  /// Where the bridge was looked for or found.
  final String? path;

  /// The evidence — the server's own `serverInfo`, or the error as the OS or
  /// the process reported it.
  final String? detail;

  bool get ok => verdict == McpBridgeVerdict.answering;
}

/// Spawns `karmashala_mcp` and speaks one `initialize` handshake to it.
///
/// Not `existsSync`: the four things that must hold — the file is there, the OS
/// will start it, it speaks MCP, and it does so promptly — are the four this
/// separates. `initialize` and not `tools/list`, because whether the *app*
/// answers is [ControlServerStatus]'s to report and it knows which step failed.
/// This spawns the bridge the way *this host* would; a WSL session spawns it
/// over interop, which the interop check speaks for.
class McpBridgeProbe {
  McpBridgeProbe({
    required this.runner,
    File? Function()? bridgeExecutable,
    this.timeout = const Duration(seconds: 5),
  }) : _locate = bridgeExecutable ?? const LauncherMcp().bridgeExecutable;

  /// Where the bridge is spawned. The host runner in the app; a fake in tests,
  /// which is why nothing here reaches for `Process` directly.
  final CommandRunner runner;

  final File? Function() _locate;

  /// How long the handshake is given.
  ///
  /// **Measured 2026-09-03 against the compiled bridge on the owner's Windows
  /// machine: 121 ms median, 111-125 ms warm, 875 ms on the first spawn of a
  /// freshly written executable.** Five seconds is forty times the worst warm
  /// case, so a timeout here is a real fault rather than a slow disk.
  final Duration timeout;

  /// The `initialize` request, as a client would send it. `2025-06-18` rather
  /// than the newest revision: it is one of the versions `kMcpAdvertisedVersions`
  /// recommends, so this probe exercises the path a real client takes.
  static const String initializeRequest =
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
      '{"protocolVersion":"2025-06-18","capabilities":{},'
      '"clientInfo":{"name":"karmashala-health","version":"1"}}}';

  Future<McpBridgeProbeResult> probe() async {
    final stopwatch = Stopwatch()..start();
    final executable = _locate();
    if (executable == null) {
      return McpBridgeProbeResult(
        verdict: McpBridgeVerdict.absent,
        took: stopwatch.elapsed,
      );
    }
    final path = executable.path;

    ProcessHandle handle;
    try {
      handle = await runner.start(CommandRequest(executable: path));
    } on Object catch (error) {
      // Every start failure, not just [CommandException]: the interop failure
      // this exists for arrives as a raw OS error on some hosts, and letting it
      // through would crash the panel instead of reporting it.
      return McpBridgeProbeResult(
        verdict: McpBridgeVerdict.unspawnable,
        took: stopwatch.elapsed,
        path: path,
        detail: _describe(error),
      );
    }

    final stderr = <String>[];
    final stderrSubscription = handle.stderrLines.listen(
      (line) => stderr.add(line),
      onError: (_) {},
    );
    try {
      final reply = await _firstReply(handle);
      return McpBridgeProbeResult(
        verdict: reply.verdict,
        took: stopwatch.elapsed,
        path: path,
        detail: reply.detail ?? (stderr.isEmpty ? null : stderr.first),
      );
    } finally {
      unawaited(stderrSubscription.cancel());
      // The bridge is a long-lived server; it has no reason to stop on its own
      // and a probe that left one behind per check would be its own bug.
      unawaited(handle.kill());
    }
  }

  Future<_Reply> _firstReply(ProcessHandle handle) async {
    final first = Completer<_Reply>();
    final subscription = handle.stdoutLines.listen(
      (line) {
        if (first.isCompleted || line.trim().isEmpty) return;
        first.complete(_classify(line));
      },
      onError: (Object error) {
        if (!first.isCompleted) {
          first.complete(
            _Reply(McpBridgeVerdict.noHandshake, 'stdout failed: $error'),
          );
        }
      },
      onDone: () {
        if (!first.isCompleted) {
          first.complete(
            const _Reply(
              McpBridgeVerdict.noHandshake,
              'The process ended without answering.',
            ),
          );
        }
      },
    );
    unawaited(
      handle.exitCode.then((code) {
        if (!first.isCompleted) {
          first.complete(
            _Reply(
              McpBridgeVerdict.noHandshake,
              'The process exited with code $code before answering.',
            ),
          );
        }
      }).catchError((Object _) {}),
    );

    try {
      handle.writeLine(initializeRequest);
    } on Object catch (error) {
      unawaited(subscription.cancel());
      return _Reply(
        McpBridgeVerdict.noHandshake,
        'stdin was refused: ${_describe(error)}',
      );
    }

    try {
      return await first.future.timeout(
        timeout,
        onTimeout: () => _Reply(
          McpBridgeVerdict.noHandshake,
          'No reply within ${timeout.inSeconds}s.',
        ),
      );
    } finally {
      unawaited(subscription.cancel());
    }
  }

  /// Reads the first line the bridge wrote as a JSON-RPC response.
  static _Reply _classify(String line) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return _Reply(
        McpBridgeVerdict.noHandshake,
        'Answered with something that is not JSON: ${_clip(line)}',
      );
    }
    if (decoded is! Map) {
      return _Reply(
        McpBridgeVerdict.noHandshake,
        'Answered with something that is not a JSON-RPC message: '
        '${_clip(line)}',
      );
    }
    if (decoded['error'] case final Map<Object?, Object?> error) {
      return _Reply(
        McpBridgeVerdict.noHandshake,
        'Refused the handshake: ${error['message'] ?? error}',
      );
    }
    final result = decoded['result'];
    if (result is! Map) {
      return _Reply(
        McpBridgeVerdict.noHandshake,
        'Answered without a result: ${_clip(line)}',
      );
    }
    final info = result['serverInfo'];
    final name = info is Map ? info['name'] : null;
    final version = info is Map ? info['version'] : null;
    final protocol = result['protocolVersion'];
    if (name == null && protocol == null) {
      return _Reply(
        McpBridgeVerdict.noHandshake,
        'Answered, but not with an MCP initialize result: ${_clip(line)}',
      );
    }
    return _Reply(
      McpBridgeVerdict.answering,
      [
        if (name != null) 'server $name${version == null ? '' : ' $version'}',
        if (protocol != null) 'protocol $protocol',
      ].join(', '),
    );
  }

  static String _describe(Object error) => switch (error) {
    CommandException(:final cause?) => '$cause',
    _ => '$error',
  };

  static String _clip(String line) =>
      line.length <= 160 ? line : '${line.substring(0, 160)}…';
}

class _Reply {
  const _Reply(this.verdict, this.detail);
  final McpBridgeVerdict verdict;
  final String? detail;
}

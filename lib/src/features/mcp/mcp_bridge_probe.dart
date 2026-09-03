import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/process/command_runner.dart';
import '../../core/process/process_handle.dart';
import 'launcher_mcp.dart';

/// What a probe of the stdio bridge found.
///
/// Four outcomes, because they need four different responses from the user —
/// and because the panel that used to report this had only two, "the file is
/// there" and "the file is not there", which is why it spent an hour on
/// 2026-09-03 saying *Tools available* while every agent session on the machine
/// had lost every Karmashala tool.
enum McpBridgeVerdict {
  /// Spawned, and completed an MCP `initialize` handshake.
  answering,

  /// On disk, but the process would not start. Today's failure: WSL's interop
  /// handler had gone, so `posix_spawn` of any Windows executable returned
  /// `ENOEXEC` — the file was never the problem.
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
/// **Why a handshake and not `existsSync`.** The question a user has is "can an
/// agent get tools from this app", and a file's presence answers a different,
/// weaker one. The four things that must hold — the file is there, the OS will
/// start it, the process speaks MCP, and it does so promptly — are exactly the
/// four this probe separates, and only the first was ever being checked.
///
/// **Why `initialize` and not `tools/list`.** The bridge answers `initialize`
/// out of its own code, with no reference to the app; `tools/list` is forwarded
/// over the owner-only socket and so also measures whether the app is willing
/// to answer. That second half is already reported, without spawning anything,
/// by [ControlServerStatus] — which knows *which* hardening step failed, a
/// thing a failed forward could only guess at. Probing it here would be a
/// second opinion that can disagree with the first. So the split is: this says
/// the bridge runs, `ControlServerStatus` says the app answers it, and the two
/// together are the whole path.
///
/// **What it does not say.** This spawns the bridge the way *this host* would.
/// A session inside WSL spawns the same file over WSL interop, which is a
/// different mechanism that can be broken while this one is fine — see the
/// interop check, which is what speaks for those sessions.
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
  /// freshly written executable.** Almost all of it is process start; the
  /// bridge answers `initialize` out of its own code without touching the app.
  /// Five seconds is therefore forty times the worst warm case and six times a
  /// cold one, so a timeout here is a real fault rather than a slow disk — and
  /// it is still short enough that a wedged bridge does not hold the panel.
  final Duration timeout;

  /// The `initialize` request, as a client would send it.
  ///
  /// `2025-06-18` rather than the newest revision on purpose: it is one of the
  /// versions `kMcpAdvertisedVersions` recommends, so this probe exercises the
  /// path a real client actually takes rather than one nothing uses.
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
      // this exists for arrives as a raw OS error on some hosts, and a probe
      // that let it through would crash the panel instead of reporting it.
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

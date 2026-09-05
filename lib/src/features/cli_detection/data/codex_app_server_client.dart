import 'dart:async';
import 'dart:convert';

import '../../../core/process/process_handle.dart';

/// Why a Codex app-server call produced no result.
enum CodexAppServerFailureKind {
  /// The process could not be started at all.
  unavailable,

  /// The `initialize` result named a different `codexHome` than the caller meant.
  wrongStore,

  /// Nothing answered inside the call's budget.
  timeout,

  /// The app-server exited before answering.
  exited,

  /// Codex answered with a JSON-RPC `error` object.
  rpcError,

  /// A reply arrived that is not a shape this client understands.
  malformed,

  /// The client was closed.
  closed,
}

/// A Codex app-server call that did not succeed.
///
/// Every failure mode is one of these — a spawn that was refused, a timeout, a
/// non-zero exit, a malformed line, and the `-32600` an unknown method answers
/// with. Callers fall back on it; nothing escapes as a raw exception.
class CodexAppServerFailure implements Exception {
  const CodexAppServerFailure(this.kind, this.message, {this.code, this.cause});

  final CodexAppServerFailureKind kind;
  final String message;

  /// The JSON-RPC error code, for [CodexAppServerFailureKind.rpcError].
  /// `-32600` is what an unknown method answers with.
  final int? code;

  final Object? cause;

  @override
  String toString() =>
      'CodexAppServerFailure(${kind.name}: $message'
      '${code == null ? '' : ' [$code]'}'
      '${cause == null ? '' : ' ($cause)'})';
}

/// What `initialize` said about the server that answered.
///
/// [codexHome] is the store this connection will read and write, which is the
/// only way to tell one Codex from another when several are installed.
class CodexAppServerInfo {
  const CodexAppServerInfo({
    required this.codexHome,
    required this.platformOs,
    required this.platformFamily,
    required this.userAgent,
  });

  factory CodexAppServerInfo.fromResult(Map<String, Object?> result) =>
      CodexAppServerInfo(
        codexHome: result['codexHome']?.toString() ?? '',
        platformOs: result['platformOs']?.toString() ?? '',
        platformFamily: result['platformFamily']?.toString() ?? '',
        userAgent: result['userAgent']?.toString() ?? '',
      );

  final String codexHome;
  final String platformOs;
  final String platformFamily;
  final String userAgent;

  @override
  String toString() => 'CodexAppServerInfo($codexHome, $platformOs)';
}

/// The answer to one call: a result object, or the reason there is none.
class CodexAppServerResult {
  const CodexAppServerResult.ok(Map<String, Object?> this.value)
    : failure = null;
  const CodexAppServerResult.failed(CodexAppServerFailure this.failure)
    : value = null;

  final Map<String, Object?>? value;
  final CodexAppServerFailure? failure;

  bool get ok => failure == null;
}

/// Opens the transport for one app-server connection.
///
/// A `Future<ProcessHandle>` rather than a process, so the client never touches
/// `dart:io`: in the app this is `CommandRunner.start` — the seam that decides
/// *where* a process is created — and in a test it is a `FakeProcessHandle`
/// driven by scripted JSON.
typedef CodexAppServerConnect = Future<ProcessHandle> Function();

/// A JSON-RPC 2.0 client for `codex app-server --listen stdio://`.
///
/// **One connection, many calls.** The handshake — a request `initialize`, then
/// a notification `initialized` — runs once, on the first call, and every call
/// after that is multiplexed by id over the same stdio pipe. Measured on the
/// owner's machine, spawn + `initialize` costs 1708 ms against a WSL Codex
/// 0.153.4 and 850 ms against a Windows Codex; the calls afterwards are single-
/// or low-double-digit milliseconds, which is the whole reason the connection is
/// kept rather than made per call.
///
/// **What the wire actually looks like**, measured against 0.145.0 (Windows) and
/// 0.153.4 (WSL) rather than assumed:
///
/// * Replies omit `jsonrpc`; they are `{"id":1,"result":{…}}`. Requiring the
///   field would reject every answer.
/// * Unsolicited notifications arrive on the same pipe (`remoteControl/status/
///   changed` does, immediately after the handshake). They carry no id and are
///   dropped.
/// * An **unknown method** answers `{"error":{"code":-32600,"message":"Invalid
///   request: unknown variant …"}}` — *with no id*, because the request never
///   parsed far enough to have one. A domain error (`no rollout found for thread
///   id …`) does carry its id. So an id-less error is charged to the oldest call
///   still waiting, which is exact while calls are issued one at a time and
///   degrades to "some call failed" rather than "a call hangs" if they are not.
/// * Unknown *params* are ignored silently, so sending a field a older Codex
///   does not know is safe.
///
/// **Where it runs.** Nothing here imports `dart:io` or Flutter, so it is as
/// usable from a worker isolate as from anywhere else. The one process it
/// creates is created by [CodexAppServerConnect] — `CommandRunner.start` in the
/// app — and a live `Process` cannot cross an isolate boundary, so that creation
/// is charged to whichever isolate opens the connection. That is the same
/// deliberate trade `spawnStreaming` documents: one creation per environment,
/// reused for the life of the connection, not thirty inside a frame.
class CodexAppServerClient {
  CodexAppServerClient({
    required this.connect,
    this.clientName = 'karmashala',
    this.clientTitle = 'Karmashala',
    this.clientVersion = '0.0.0',
    this.timeout = const Duration(seconds: 30),
    this.expectedCodexHome,
  });

  /// Opens the one connection this client uses. See [CodexAppServerConnect].
  final CodexAppServerConnect connect;

  final String clientName;
  final String clientTitle;
  final String clientVersion;

  /// Budget for the handshake and for each call after it.
  final Duration timeout;

  /// The store this connection is meant to be talking to, spelled the way the
  /// server itself would spell it, or `null` to accept whatever answers.
  ///
  /// Compared case-insensitively with separators normalised. A lenient compare
  /// can only ever accept a store it should have rejected, never reject the
  /// right one — and a false rejection here would block a rename that was going
  /// to work.
  final String? expectedCodexHome;

  /// Connections opened, and requests written. **Counts, never durations** —
  /// milliseconds on a shared machine are noise, and "did it hand-shake twice?"
  /// is the deterministic question.
  int connectionsOpened = 0;
  int requestsSent = 0;

  /// What `initialize` answered, once there has been a handshake.
  CodexAppServerInfo? get info => _info;
  CodexAppServerInfo? _info;

  ProcessHandle? _handle;
  Future<ProcessHandle>? _ready;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  bool _closed = false;

  int _nextId = 1;

  /// Insertion-ordered by construction, which is what lets an id-less error be
  /// charged to the oldest waiter.
  final Map<int, Completer<CodexAppServerResult>> _pending = {};

  /// The last few stderr lines, so a non-zero exit can say what Codex printed.
  final List<String> _stderrTail = [];

  /// Names the thread [threadId] `name` in Codex's own store.
  ///
  /// `thread/name/set`, which is authoritative: it writes `threads.name` in
  /// `<codexHome>/state_5.sqlite` *and* appends a fresh line to the derived
  /// `session_index.jsonl` mirror, so a file-based reader sees the new name too.
  /// (`thread/setName` does not exist — it answers `-32600`.)
  Future<CodexAppServerResult> setThreadName(String threadId, String name) =>
      call('thread/name/set', {'threadId': threadId, 'name': name});

  /// Sends one JSON-RPC request, connecting and handshaking first if needed.
  ///
  /// Never throws: everything that can go wrong comes back as a
  /// [CodexAppServerFailure] on the result.
  Future<CodexAppServerResult> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (_closed) {
      return const CodexAppServerResult.failed(
        CodexAppServerFailure(
          CodexAppServerFailureKind.closed,
          'The Codex app-server client is closed',
        ),
      );
    }
    final ProcessHandle handle;
    try {
      handle = await _connectOnce();
    } on CodexAppServerFailure catch (failure) {
      return CodexAppServerResult.failed(failure);
    }
    return _request(handle, method, params);
  }

  /// Kills the app-server and fails anything still waiting. Idempotent.
  ///
  /// Deterministic on purpose: `codex` exits on stdin EOF, but [ProcessHandle]
  /// exposes no way to close stdin, so the handle is killed rather than left to
  /// notice. Nothing is leaked either way.
  Future<void> close() async {
    _closed = true;
    await _teardown(
      const CodexAppServerFailure(
        CodexAppServerFailureKind.closed,
        'The Codex app-server client was closed',
      ),
    );
  }

  /// Kills the connection and fails what was waiting on it, without deciding
  /// whether the client itself is finished — a handshake that failed tears down
  /// but stays reusable, [close] does not.
  Future<void> _teardown(CodexAppServerFailure failure) async {
    final handle = _handle;
    _handle = null;
    _ready = null;
    _failPending(failure);
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
    _stderrTail.clear();
    if (handle != null) {
      try {
        await handle.kill();
      } on Object {
        // A process that is already gone is the outcome we wanted.
      }
    }
  }

  /// The one connection, opened at most once at a time. A failed attempt is
  /// forgotten rather than cached, so the next call may try again.
  Future<ProcessHandle> _connectOnce() async {
    final existing = _ready;
    if (existing != null) return existing;
    final opening = _open();
    _ready = opening;
    try {
      return await opening;
    } on Object {
      if (identical(_ready, opening)) _ready = null;
      rethrow;
    }
  }

  Future<ProcessHandle> _open() async {
    final ProcessHandle handle;
    try {
      handle = await connect();
    } on Object catch (error) {
      throw CodexAppServerFailure(
        CodexAppServerFailureKind.unavailable,
        'Could not start the Codex app-server',
        cause: error,
      );
    }
    connectionsOpened++;
    _handle = handle;
    _stdout = handle.stdoutLines.listen(_onLine, onError: (Object _) {});
    _stderr = handle.stderrLines.listen(
      _rememberStderr,
      onError: (Object _) {},
    );
    unawaited(
      handle.exitCode.then(_onExit).catchError((Object _) {}),
    );

    final init = await _request(handle, 'initialize', {
      'clientInfo': {
        'name': clientName,
        'title': clientTitle,
        'version': clientVersion,
      },
    });
    final failure = init.failure ?? _rejectWrongStore(init.value!);
    if (failure != null) {
      await _teardown(failure);
      throw failure;
    }
    _info = CodexAppServerInfo.fromResult(init.value!);
    handle.writeLine(
      jsonEncode({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}}),
    );
    return handle;
  }

  CodexAppServerFailure? _rejectWrongStore(Map<String, Object?> initResult) {
    final expected = expectedCodexHome;
    if (expected == null) return null;
    final reported = initResult['codexHome']?.toString() ?? '';
    if (_sameStore(expected, reported)) return null;
    return CodexAppServerFailure(
      CodexAppServerFailureKind.wrongStore,
      'The Codex app-server serves "$reported", not "$expected"',
    );
  }

  static bool _sameStore(String a, String b) =>
      _normaliseHome(a) == _normaliseHome(b);

  static String _normaliseHome(String path) {
    final slashed = path.replaceAll(r'\', '/');
    final trimmed = slashed.length > 1
        ? slashed.replaceFirst(RegExp(r'/+$'), '')
        : slashed;
    return trimmed.toLowerCase();
  }

  Future<CodexAppServerResult> _request(
    ProcessHandle handle,
    String method,
    Map<String, Object?> params,
  ) {
    final id = _nextId++;
    final completer = Completer<CodexAppServerResult>();
    _pending[id] = completer;
    try {
      handle.writeLine(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      );
    } on Object catch (error) {
      _pending.remove(id);
      return Future.value(
        CodexAppServerResult.failed(
          CodexAppServerFailure(
            CodexAppServerFailureKind.unavailable,
            'Could not write "$method" to the Codex app-server',
            cause: error,
          ),
        ),
      );
    }
    requestsSent++;
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        return CodexAppServerResult.failed(
          CodexAppServerFailure(
            CodexAppServerFailureKind.timeout,
            'The Codex app-server did not answer "$method" in time',
          ),
        );
      },
    );
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      // Codex prints warnings on stdout on some hosts; a line that is not JSON
      // is not an answer, and dropping it is not a failure of any call.
      return;
    }
    if (decoded is! Map<String, Object?>) return;

    final id = decoded['id'];
    final error = decoded['error'];
    if (id is! int) {
      if (error != null) _failOldest(_rpcFailure(error));
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (error != null) {
      completer.complete(CodexAppServerResult.failed(_rpcFailure(error)));
      return;
    }
    final result = decoded['result'];
    completer.complete(
      result is Map<String, Object?>
          ? CodexAppServerResult.ok(result)
          : const CodexAppServerResult.failed(
              CodexAppServerFailure(
                CodexAppServerFailureKind.malformed,
                'The Codex app-server answered without a result object',
              ),
            ),
    );
  }

  CodexAppServerFailure _rpcFailure(Object? error) {
    if (error is! Map) {
      return CodexAppServerFailure(
        CodexAppServerFailureKind.malformed,
        'The Codex app-server answered with an unreadable error: $error',
      );
    }
    final code = error['code'];
    return CodexAppServerFailure(
      CodexAppServerFailureKind.rpcError,
      error['message']?.toString() ?? 'The Codex app-server refused the call',
      code: code is int ? code : null,
    );
  }

  void _rememberStderr(String line) {
    if (line.trim().isEmpty) return;
    _stderrTail.add(line);
    if (_stderrTail.length > 5) _stderrTail.removeAt(0);
  }

  void _onExit(int code) {
    _handle = null;
    _ready = null;
    _failPending(
      CodexAppServerFailure(
        CodexAppServerFailureKind.exited,
        'The Codex app-server exited with code $code'
        '${_stderrTail.isEmpty ? '' : ': ${_stderrTail.join(' / ')}'}',
      ),
    );
  }

  /// Charges an error that named no id to the call that has been waiting
  /// longest — see the class doc for why an unknown method arrives that way.
  void _failOldest(CodexAppServerFailure failure) {
    if (_pending.isEmpty) return;
    final oldest = _pending.keys.first;
    _pending.remove(oldest)?.complete(CodexAppServerResult.failed(failure));
  }

  void _failPending(CodexAppServerFailure failure) {
    final waiting = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in waiting) {
      if (!completer.isCompleted) {
        completer.complete(CodexAppServerResult.failed(failure));
      }
    }
  }
}

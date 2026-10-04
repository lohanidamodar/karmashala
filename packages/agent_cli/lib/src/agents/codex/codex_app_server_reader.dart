import 'dart:async';

import '../../process/command_runner.dart';
import '../../process/command_runner_factory.dart';
import '../../process/path_translator.dart';
import '../domain/agent_ids.dart';
import '../../environments/environment_kind.dart';
import '../../environments/environment_path.dart';
import '../../environments/execution_environment.dart';
import '../../environments/local_environment.dart';
import '../../cli_detection/domain/detected_session.dart';
import './codex_app_server_client.dart';
import '../adapter/store_server_launch.dart';
import './codex_store_reader.dart';
import './codex_store_server.dart';
import '../../cli_detection/data/store_scan_slots.dart';
import '../../cli_detection/data/store_session_reader.dart';

/// Reads Codex sessions from `codex app-server`'s own index instead of from the
/// rollout files.
///
/// **Why, in two defects the file walk cannot fix.** A rollout's first
/// `role:user` `input_text` is an injected preamble — `<recommended_plugins>`,
/// `# AGENTS.md instructions for …` — so 15 of the owner's 16 sessions were
/// labelled with junk, and 10 of them have no name at all and fall back to that
/// preview for their whole display title. And `cwd` is read first-wins from the
/// opening `session_meta`, while Codex re-stamps it in every `turn_context`: a
/// session that changes directory stays filed under the project it began in.
/// `thread/list` answers both from the state Codex itself keeps current.
///
/// **[CodexStoreReader] is the fallback, not dead code.** One environment whose
/// Codex will not spawn, hand-shake or answer falls back to the file walk; every
/// other install keeps using the protocol. The fallback also carries the store
/// homes no app-server was resolved for at all.
class CodexAppServerReader implements StoreSessionReader {
  CodexAppServerReader({
    StoreSessionReader? fallback,
    this.openClient,
    this.runnerFactory = const CommandRunnerFactory(),
    this.translator = const PathTranslator(),
    this.clientVersion = '0.0.0',
  }) : fallback = fallback ?? CodexStoreReader();

  /// The file walk, used whenever the protocol cannot answer.
  final StoreSessionReader fallback;

  /// Builds the client for one launch. Null means [_open], which is the real
  /// thing; a test hands back a client wired to a scripted server instead.
  final CodexAppServerClient Function(
    StoreServerLaunch launch,
    String? expectedCodexHome,
  )?
  openClient;

  final CommandRunnerFactory runnerFactory;
  final PathTranslator translator;
  final String clientVersion;

  final Map<String, _CodexConnection> _byEnvironment = {};

  /// Rows the protocol answered with, and scans that fell back to the walk.
  /// **Counts, never durations** — "did this environment stop using the
  /// protocol?" is the deterministic question.
  int threadsRead = 0;
  int fallbacksServed = 0;

  /// Why each environment last fell back, so a failure is inspectable rather
  /// than merely silent. Nothing logs here: the worker isolate installs no
  /// logging handler, so a line written there goes nowhere.
  final Map<String, CodexAppServerFailure> lastFailureByEnvironment = {};

  /// [directories] is ignored for the same reason [CodexStoreReader] ignores
  /// it: Codex's layout is not addressable from a working directory. [slots]
  /// bounds file reads and there are none here — one call answers the store.
  @override
  Future<List<DetectedSession>> read(
    String storeHome,
    String environmentId, {
    Set<String>? directories,
    StoreScanSlots? slots,
    StoreServerLaunch? storeServer,
  }) async {
    Future<List<DetectedSession>> walk() {
      fallbacksServed++;
      return fallback.read(
        storeHome,
        environmentId,
        directories: directories,
        slots: slots,
      );
    }

    if (storeServer == null || storeServer.environmentId != environmentId) {
      return walk();
    }
    final connection = _connectionFor(storeServer, storeHome);
    if (connection == null) return walk();

    final list = await connection.client.listThreads();
    final failure = list.failure;
    if (failure != null) {
      connection.recordFailure();
      lastFailureByEnvironment[environmentId] = failure;
      return walk();
    }
    connection.recordSuccess();
    lastFailureByEnvironment.remove(environmentId);

    final sessions = <DetectedSession>[];
    for (final thread in list.threads) {
      final filePath = _hostPath(thread.path, storeServer.environment);
      // A thread with no rollout this host can open is one the file walk would
      // not have found either, and `filePath` is half of `DetectedSession`'s
      // identity — so dropping it is parity, not loss.
      if (filePath == null) continue;
      sessions.add(
        DetectedSession(
          cli: AgentIds.codex,
          sessionId: thread.id,
          cwd: EnvironmentPath(environmentId: environmentId, path: thread.cwd),
          filePath: filePath,
          storeHome: storeHome,
          title: thread.name,
          preview: _preview(thread.preview),
          startedAt: thread.createdAt,
          modifiedAt: thread.updatedAt,
        ),
      );
    }
    threadsRead += sessions.length;
    return sessions;
  }

  /// Closes every connection this reader opened.
  Future<void> close() async {
    final open = _byEnvironment.values.toList(growable: false);
    _byEnvironment.clear();
    for (final connection in open) {
      await connection.client.close();
    }
  }

  /// The connection for [launch], or `null` while this environment is serving
  /// its backoff.
  _CodexConnection? _connectionFor(StoreServerLaunch launch, String storeHome) {
    final existing = _byEnvironment[launch.environmentId];
    if (existing != null && existing.executable == launch.executable) {
      return existing.readyForAnotherAttempt() ? existing : null;
    }
    // A Codex that moved is a different install; the old connection is stale.
    if (existing != null) unawaited(existing.client.close());

    final expectedHome = _expectedHomeIn(launch.environment, storeHome);
    final CodexAppServerClient client;
    try {
      client = (openClient ?? _open)(launch, expectedHome);
    } on Object {
      // An SSH environment with no connection pool composed, most likely. The
      // walk is the whole answer for a store we cannot reach a runner for.
      return null;
    }
    final connection = _CodexConnection(launch.executable, client);
    _byEnvironment[launch.environmentId] = connection;
    return connection;
  }

  CodexAppServerClient _open(
    StoreServerLaunch launch,
    String? expectedCodexHome,
  ) {
    final runner = runnerFactory.forEnvironment(launch.environment);
    return CodexAppServerClient(
      connect: () => runner.start(
        CommandRequest(
          executable: launch.executable,
          arguments: codexAppServerArguments,
        ),
      ),
      clientVersion: clientVersion,
      expectedCodexHome: expectedCodexHome,
    );
  }

  /// [storeHome] — which this host spells, so `\\wsl.localhost\…` for WSL — in
  /// the environment's own spelling, which is how `initialize` reports it.
  String? _expectedHomeIn(ExecutionEnvironment environment, String storeHome) {
    if (storeHome.isEmpty) return null;
    if (environment.kind != EnvironmentKind.wsl) return storeHome;
    try {
      return translator
          .translate(
            EnvironmentPath(
              environmentId: localHostEnvironmentId,
              path: storeHome,
            ),
            from: windowsHostEnvironment(_unused),
            to: environment,
          )
          .path;
    } on PathTranslationException {
      // No assertion at all beats a wrong one; the handshake still has to name
      // a Codex, it just is not checked against a home we could not spell.
      return null;
    }
  }

  /// The rollout path as **this host** can open it.
  ///
  /// `thread/list` reports the path Codex sees, which for a WSL install is a
  /// path inside the distribution. `filePath` feeds transcript reading and the
  /// session mutator, both of which call `File(...)` on it, so it has to be the
  /// `\\wsl.localhost\…` UNC form the file walk would have produced — the same
  /// translation `CliStoreLocator` uses for the store home itself.
  String? _hostPath(String? path, ExecutionEnvironment environment) {
    if (path == null || path.isEmpty) return null;
    if (environment.kind != EnvironmentKind.wsl) return path;
    try {
      return translator
          .translate(
            EnvironmentPath(environmentId: environment.id, path: path),
            from: environment,
            to: windowsHostEnvironment(_unused),
          )
          .path;
    } on PathTranslationException {
      return null;
    }
  }

  /// The same shape [CodexStoreReader] gives a preview — whitespace collapsed,
  /// 120 characters — so a fallback does not change how a session is labelled.
  static String _preview(String raw) {
    // A block Codex injected is not what anybody typed, and titled rows
    // `<recommended_plugins> Here is a list…`.
    if (codexInjectedContext.opensInjected(raw)) return '';
    final trimmed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length <= 120) return trimmed;
    return '${trimmed.substring(0, 119)}…';
  }
}

/// One environment's connection, and how many scans it is sitting out.
class _CodexConnection {
  _CodexConnection(this.executable, this.client);

  final String executable;
  final CodexAppServerClient client;

  int failures = 0;
  int _scansToSkip = 0;

  /// Whether this scan may try the protocol again.
  ///
  /// **Backoff counted in scans, not seconds.** A store scan runs on the status
  /// registry's slow slot, so an environment whose Codex will not answer would
  /// otherwise pay a failed spawn — up to the client's whole timeout — every
  /// pass. Doubling the scans skipped after each failure keeps a permanent
  /// breakage cheap without making a transient one permanent.
  bool readyForAnotherAttempt() {
    if (_scansToSkip <= 0) return true;
    _scansToSkip--;
    return false;
  }

  void recordFailure() {
    failures++;
    _scansToSkip = failures >= 6 ? 32 : 1 << (failures - 1);
  }

  void recordSuccess() {
    failures = 0;
    _scansToSkip = 0;
  }
}

/// `createdAt` is not read by any translation; the stand-in keeps the two
/// synthetic environments above from pretending to know a creation time.
final DateTime _unused = DateTime.utc(1970);

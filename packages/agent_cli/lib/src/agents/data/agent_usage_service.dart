import 'dart:io';

import 'package:meta/meta.dart';

import '../../util/clock.dart';
import '../../cli_detection/data/cli_store.dart';
import '../../environments/execution_environment.dart';
import '../adapter/agent_usage_endpoint.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_registry.dart';
import '../domain/agent_usage.dart';
import '../domain/usage_failure.dart';
import '../claude_code/claude_auth_service.dart';
import './agent_home_locator.dart';
import './usage_exception.dart';
import './usage_http.dart';
import './usage_throttle.dart';
import '../../environments/environment_label.dart';

/// Told about a fresh reading — see [AgentUsageService.addReadingListener].
typedef UsageReadingListener =
    void Function(AgentInstallation installation, AgentUsage usage);

/// Fetches live usage/limit data for an agent installation, from the endpoint
/// its adapter declares (`AgentUsageSupport.endpoint`) — the same one the
/// vendor's own app asks, authorised with the token the installation already
/// stores. An agent whose adapter declares none is told so, not asked.
///
/// **Every request the app makes to either endpoint goes through [fetch]**, and
/// [fetch] is where the [UsageThrottle] sits: it serves a reading the app
/// already has rather than asking again inside this account's floor, and it
/// refuses outright while a `429` is still in force. That is deliberate — the
/// chip, the settings panel, the fan-out dialog and the MCP tool each used to be
/// their own unrated request path, which is how a user with several panes could
/// spend far more than the poll interval suggested.
class AgentUsageService {
  AgentUsageService({
    required this.storeLocator,
    required this.clock,
    HttpClient Function()? httpClientFactory,
    ClaudeKeychainCache? keychain,
    bool? hostIsMacOS,
    UsageThrottle? throttle,
    this.registry = AgentRegistry.builtIn,
  }) : _http = UsageHttp(
         newClient: httpClientFactory ?? HttpClient.new,
         clock: clock,
       ),
       _keychain = keychain ?? claudeKeychain,
       _homes = AgentHomeLocator(storeLocator, hostIsMacOS: hostIsMacOS),
       _throttle = throttle ?? UsageThrottle(clock: clock);

  final CliStoreLocator storeLocator;
  final Clock clock;

  /// Where each agent's usage endpoint is found.
  final AgentRegistry registry;

  final UsageHttp _http;

  /// What was read last, and how long the vendor said to wait. Shared by every
  /// caller of this service, which is the point: one account, one limit.
  final UsageThrottle _throttle;

  /// The memo in front of `security find-generic-password`. Injectable so a
  /// test can count the spawns this service causes.
  final ClaudeKeychainCache _keychain;

  /// Where each installation's files are, and how to read them. Takes
  /// `hostIsMacOS` for the reason `CliStoreLocator.environment` is injected:
  /// the Keychain branch has to be testable off a Mac.
  final AgentHomeLocator _homes;

  /// The last reading taken for this account, however old, or null if none was
  /// taken in this run.
  ///
  /// **Every surface shows this when a lookup fails**, with its age beside it.
  /// A number the app read four minutes ago is worth more than a dash, as long
  /// as it never pretends to be live — the reason `AgentStatusReport.evidenceAt`
  /// exists.
  AgentUsage? remembered(AgentInstallation installation) =>
      _throttle.remembered(installation);

  /// The refusal this account would get if it asked right now, or null.
  ///
  /// So a surface can say *why* the number is not moving without making the
  /// request that would tell it — the settings panel opens on this rather than
  /// looking untroubled while the chip shows a stalled reading. Recomputed on
  /// every call, so the countdown in it is the one that is true now.
  UsageException? pendingPause(AgentInstallation installation) {
    final pause = _throttle.pauseFor(installation);
    return pause == null ? null : _waiting(pause);
  }

  /// A reading young enough to stand in for a fresh one, or null.
  ///
  /// Consulted by [fetch] itself — see there. Public because a surface may want
  /// to know whether the number it is about to show came off the wire.
  AgentUsage? rememberedIfFresh(AgentInstallation installation) =>
      _throttle.rememberedIfFresh(installation);

  /// How long a reading stands in for a fresh one, for this account.
  ///
  /// Read off the payload — [usageAskFloor] — so a five-hour quota is three
  /// minutes and a reply that named no period is one.
  Duration askFloor(AgentInstallation installation) =>
      _throttle.floorFor(installation);

  /// How long until this account is worth asking about on the app's own
  /// initiative. `UsageRefreshController` arms its tick at this.
  Duration dueIn(AgentInstallation installation) =>
      _throttle.dueIn(installation);

  /// [dueIn] by account key, for the refresh policy — which is keyed by account
  /// and therefore never holds an installation of its own.
  Duration dueInForAccount(String accountKey) =>
      _throttle.dueInForKey(accountKey);

  /// Fetches usage for [installation]. Throws [UsageException] on any failure.
  ///
  /// **Two things happen before a socket is opened**, and both are here rather
  /// than in a caller, because "every caller remembered to check" is not a
  /// property a rate limit can be defended with:
  ///
  /// * a reading inside this account's floor is handed straight back. The floor
  ///   is the shortest time in which the quota can move by a point
  ///   ([usageAskFloor]), so the request it skips could not have learned
  ///   anything. This is the one place the app's request rate is bounded — the
  ///   tick, the chip's click, a session's status moving, the Settings button,
  ///   the fan-out dialog and the MCP tool all arrive here, and four of them
  ///   used to arrive unconditionally.
  /// * a rate limit still in force refuses without asking. The whole point of a
  ///   backoff is that the request is not made.
  Future<AgentUsage> fetch(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    final fresh = _throttle.rememberedIfFresh(installation);
    if (fresh != null) return fresh;
    final pending = pendingPause(installation);
    if (pending != null) throw pending;
    try {
      final usage = await fetchFresh(installation, environments);
      _throttle.recordSuccess(installation, usage);
      _announce(installation, usage);
      return usage;
    } on UsageException catch (e) {
      if (!_worthWaitingOut(e.kind)) rethrow;
      // The server's own `Retry-After` when it sent one, our doubling when it
      // did not. Either way the wait is decided here, where the consecutive
      // count lives, and not at the socket.
      throw _waiting(
        _throttle.recordRefusal(
          installation,
          kind: e.kind,
          reason: e.message,
          retryAfter: e.retryIn,
        ),
      );
    }
  }

  final _readingListeners = <UsageReadingListener>[];

  /// Called with every reading that came off the wire — never with one served
  /// from memory inside the floor, so a history built on it records each
  /// request once and costs no request of its own.
  void addReadingListener(UsageReadingListener listener) =>
      _readingListeners.add(listener);

  void removeReadingListener(UsageReadingListener listener) =>
      _readingListeners.remove(listener);

  void _announce(AgentInstallation installation, AgentUsage usage) {
    for (final listener in [..._readingListeners]) {
      try {
        listener(installation, usage);
      } on Object {
        // A listener's failure is its own; the reading still stands.
      }
    }
  }

  /// The two failures that mean *stop asking*: being throttled, and pushing on
  /// a server that is already struggling. An expired token and an unreachable
  /// endpoint are neither — the first is fixed by the user and must be noticed
  /// on the next tick, and the second costs the vendor nothing.
  static bool _worthWaitingOut(UsageFailureKind kind) =>
      kind == UsageFailureKind.rateLimited ||
      kind == UsageFailureKind.serverBusy;

  UsageException _waiting(UsagePause pause) => UsageException(
    '${pause.reason} Waiting ${describeUsageWait(pause.wait)} before asking '
    'again.',
    kind: pause.kind,
    retryIn: pause.wait,
  );

  /// The lookup itself, with no memory and no backoff in front of it.
  ///
  /// Separate from [fetch] so a test double can answer the network half while
  /// still being throttled and remembered exactly like the real one.
  @protected
  @visibleForOverriding
  Future<AgentUsage> fetchFresh(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    // Only an agent whose adapter declares a usage endpoint is asked. Any
    // other agent — including one we have never heard of — is told plainly.
    final agentId = installation.agentId;
    final endpoint = registry.adapterFor(agentId)?.usage?.endpoint;
    if (endpoint == null) {
      throw UsageException(
        'Usage is not available for ${registry.displayNameFor(agentId)}.',
        kind: UsageFailureKind.notAsked,
      );
    }
    // The same home the Accounts page reads, so an SSH installation is read on
    // its own host rather than refused for having no local store.
    final home = await _homes.homeFor(
      agentId,
      installation.environmentId,
      environments,
    );
    if (home == null) {
      throw UsageException(
        'Could not locate the store for ${describeEnvironmentId(installation.environmentId)}.',
        kind: UsageFailureKind.notAsked,
      );
    }
    return endpoint.read(
      UsageReadContext(
        storeHome: home.path,
        paths: home.paths,
        localMacHost: home.localMacHost,
        homeFromVariable: home.fromVariable,
        io: home.io,
        http: _http,
        clock: clock,
        keychain: _keychain,
      ),
    );
  }
}

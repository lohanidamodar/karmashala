import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../data/data_service.dart';

/// **Who is signed in to each agent, and switching who is** — done by the
/// server, on the machine whose credential files (or login Keychain) they
/// are. It reads the signed-in identity (never the token) for a client
/// (`accounts.current`), captures the signed-in account into the saved ones
/// (`accounts.capture`), and signs an installation in as a saved account
/// (`accounts.switch`), capturing the outgoing one first so it can be
/// switched back to.
///
/// **A token bundle never leaves the server**: captured here, kept in its
/// store, read back here to write it into the agent's files. No answer,
/// change or log line carries one; a refusal carries the auth service's
/// sentence, which names files and accounts, never values.
///
/// Which switcher applies is the installation's accounts *capability* — the
/// sign-in mechanism — never its agent id.
class ServerAccounts {
  ServerAccounts({
    required DataService data,
    required CliStoreLocator stores,
    required this.ids,
    this.clock = const SystemClock(),
    this.registry = AgentRegistry.builtIn,
    ClaudeAuthService? claude,
    CodexAuthService? codex,
  }) : _data = data,
       _claudeLocator = ClaudeAuthLocator(stores),
       _codexLocator = CodexAuthLocator(stores),
       _claude = claude ?? ClaudeAuthService(ids: ids, clock: clock),
       _codex = codex ?? CodexAuthService(ids: ids, clock: clock);

  final DataService _data;
  final IdGenerator ids;
  final Clock clock;
  final AgentRegistry registry;
  final ClaudeAuthLocator _claudeLocator;
  final CodexAuthLocator _codexLocator;
  final ClaudeAuthService _claude;
  final CodexAuthService _codex;

  /// Who is signed in to [installationId] now.
  Future<AgentSignIn> current(String installationId) async {
    final installation = _installation(installationId);
    switch (_accountsOf(installation)) {
      case AnthropicOAuthAccounts():
        final paths = await _claudeLocator.pathsFor(
          installation,
          _data.environments,
        );
        if (paths == null) {
          return AnthropicSignIn(
            ClaudeAuthSnapshot.signedOut(installation.environmentId),
          );
        }
        final snapshot = await _claude.readSnapshot(paths);
        final expiresAt = snapshot.accessTokenExpiresAt;
        return AnthropicSignIn(
          snapshot,
          // `hasUsableLogin`, from the one reading rather than a second.
          usableLogin:
              snapshot.isSignedIn &&
              (expiresAt == null || expiresAt.isAfter(clock.nowUtc())),
        );
      case OpenAiAuthFileAccounts():
        final location = await _codexLocator.locationFor(
          installation,
          _data.environments,
        );
        if (location == null) {
          return OpenAiSignIn(
            CodexAuthSnapshot.signedOut(installation.environmentId),
          );
        }
        return OpenAiSignIn(
          await _codex.readSnapshot(
            location.path,
            installation.environmentId,
            io: location.io,
          ),
        );
      case null:
        return const NoSignIn();
    }
  }

  /// Captures the account signed in to [installationId] and saves it;
  /// answers the saved account's id.
  Future<String> capture(String installationId) async {
    final installation = _installation(installationId);
    switch (_accountsOf(installation)) {
      case AnthropicOAuthAccounts():
        final paths = await _claudePaths(installation);
        final account = await _refusing(() => _claude.capture(paths));
        return _data.saveClaudeAccount(account).id;
      case OpenAiAuthFileAccounts():
        final location = await _codexLocation(installation);
        final account = await _refusing(
          () => _codex.capture(
            location.path,
            installation.environmentId,
            io: location.io,
          ),
        );
        return _data.saveCodexAccount(account).id;
      case null:
        throw _noSwitcher(installation);
    }
  }

  /// Signs [installationId] in as saved account [accountId]. The account
  /// signed in now is captured first; a missing one is no reason to stop.
  Future<void> switchTo(String installationId, String accountId) async {
    final installation = _installation(installationId);
    switch (_accountsOf(installation)) {
      case AnthropicOAuthAccounts():
        final paths = await _claudePaths(installation);
        final saved = _data.claudeAccount(accountId);
        if (saved.claudeAiOauth.isEmpty) {
          throw DataRefused.invalid(
            'The saved account ${saved.email} has no sign-in to switch to.',
          );
        }
        try {
          _data.saveClaudeAccount(await _claude.capture(paths));
        } on ClaudeAuthException {
          // Nothing signed in to keep: the switch still stands.
        }
        await _refusing(() => _claude.switchTo(saved, paths));
        // Its identity fields as the files now say them.
        _data.saveClaudeAccount(saved);
      case OpenAiAuthFileAccounts():
        final location = await _codexLocation(installation);
        final saved = _data.codexAccount(accountId);
        if (saved.auth.isEmpty) {
          throw DataRefused.invalid(
            'The saved account ${saved.email ?? saved.accountId} has no '
            'sign-in to switch to.',
          );
        }
        try {
          _data.saveCodexAccount(
            await _codex.capture(
              location.path,
              installation.environmentId,
              io: location.io,
            ),
          );
        } on CodexAuthException {
          // A missing outgoing login is valid.
        }
        await _refusing(
          () => _codex.switchTo(saved, location.path, io: location.io),
        );
      case null:
        throw _noSwitcher(installation);
    }
  }

  AgentInstallation _installation(String id) {
    for (final installation in _data.installations) {
      if (installation.id == id) return installation;
    }
    throw DataRefused.notFound('no agent installation with id $id');
  }

  AgentAccounts? _accountsOf(AgentInstallation installation) =>
      registry.adapterFor(installation.agentId)?.accounts;

  DataRefused _noSwitcher(AgentInstallation installation) =>
      DataRefused.invalid(
        '${registry.displayNameFor(installation.agentId)} has no accounts to '
        'switch.',
      );

  Future<ClaudeAuthPaths> _claudePaths(AgentInstallation installation) async =>
      await _claudeLocator.pathsFor(installation, _data.environments) ??
      (throw DataRefused.notFound(
        'Could not locate the Claude config for ${installation.environmentId}.',
      ));

  Future<CodexAuthLocation> _codexLocation(
    AgentInstallation installation,
  ) async =>
      await _codexLocator.locationFor(installation, _data.environments) ??
      (throw DataRefused.notFound(
        'Could not locate Codex auth for ${installation.environmentId}.',
      ));

  /// [work], with an auth service's refusal as the client's — its sentence,
  /// which names files and accounts, never a value.
  Future<T> _refusing<T>(Future<T> Function() work) async {
    try {
      return await work();
    } on ClaudeAuthException catch (error) {
      throw DataRefused(DataRefusalCode.failed, error.message);
    } on CodexAuthException catch (error) {
      throw DataRefused(DataRefusalCode.failed, error.message);
    }
  }
}

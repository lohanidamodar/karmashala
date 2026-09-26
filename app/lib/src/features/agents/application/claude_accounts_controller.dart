import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/agent_cli_bridge.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../data/agents_data.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/discovery.dart';

/// Locates the credential/config files for a Claude installation.
final claudeAuthLocatorProvider = Provider<ClaudeAuthLocator>(
  (ref) => ClaudeAuthLocator(ref.watch(cliStoreLocatorProvider)),
);

/// Reads/captures/switches Claude accounts.
final claudeAuthServiceProvider = Provider<ClaudeAuthService>(
  (ref) => ClaudeAuthService(
    ids: ref.watch(agentCliIdsProvider),
    clock: ref.watch(agentCliClockProvider),
  ),
);

/// The live logged-in account for one Claude installation, read from disk.
/// Keyed by installation so each Claude install refreshes independently.
final claudeAuthSnapshotProvider =
    FutureProvider.family<ClaudeAuthSnapshot, AgentInstallation>((
      ref,
      installation,
    ) async {
      final environments = ref.watch(environmentsDataProvider).getAll();
      final paths = await ref
          .watch(claudeAuthLocatorProvider)
          .pathsFor(installation, environments);
      if (paths == null) {
        return ClaudeAuthSnapshot.signedOut(installation.environmentId);
      }
      return ref.watch(claudeAuthServiceProvider).readSnapshot(paths);
    });

/// Holds the saved Claude accounts — the server's, **without their
/// credentials**, followed as they change — and drives capture/switch. A
/// token bundle is only ever asked for right before a switch writes it.
class ClaudeAccountsController extends Notifier<List<ClaudeAccount>> {
  final _logger = AppLogger.named('claude-accounts');

  ClaudeAccountsData get _data => ref.read(claudeAccountsDataProvider);

  @override
  List<ClaudeAccount> build() {
    final data = ref.watch(claudeAccountsDataProvider);
    final accounts = data.getAll();
    final listening = data.changes.listen((_) => state = data.getAll());
    ref.onDispose(listening.cancel);
    return accounts;
  }

  /// Captures the account currently logged in to [installation] and saves it
  /// at the server. Returns the saved account, without its credentials.
  /// Throws [ClaudeAuthException] on failure.
  Future<ClaudeAccount> captureCurrent(AgentInstallation installation) async {
    final paths = await _pathsFor(installation);
    final account = await ref.read(claudeAuthServiceProvider).capture(paths);
    final saved = await _data.save(account);
    state = _data.getAll();
    return saved;
  }

  /// Switches [installation] to the saved [account]. Before writing, the account
  /// currently logged in is captured so the user can always switch back.
  Future<void> switchTo(
    AgentInstallation installation,
    ClaudeAccount account,
  ) async {
    final service = ref.read(claudeAuthServiceProvider);
    final paths = await _pathsFor(installation);
    // The saved sign-in, asked for now and held only for this switch.
    final saved = await _data.credentials(account.id);
    if (saved.claudeAiOauth.isEmpty) {
      throw ClaudeAuthException(
        'The saved account ${account.email} has no sign-in to switch to.',
      );
    }

    try {
      final current = await service.capture(paths);
      await _data.save(current);
    } on ClaudeAuthException catch (e) {
      _logger.info(
        'No current account to back up before switch (${e.message}).',
      );
    }

    await service.switchTo(saved, paths);
    await _data.save(saved); // refresh denormalized fields / captured env
    state = _data.getAll();
    ref.invalidate(claudeAuthSnapshotProvider(installation));
  }

  /// Forgets a saved account (does not touch any installation's files).
  Future<void> forget(ClaudeAccount account) async {
    await _data.delete(account.id);
    state = _data.getAll();
  }

  Future<ClaudeAuthPaths> _pathsFor(AgentInstallation installation) async {
    final environments = ref.read(environmentsDataProvider).getAll();
    final paths = await ref
        .read(claudeAuthLocatorProvider)
        .pathsFor(installation, environments);
    if (paths == null) {
      throw ClaudeAuthException(
        'Could not locate the Claude config for ${installation.environmentId}.',
      );
    }
    return paths;
  }
}

final claudeAccountsControllerProvider =
    NotifierProvider<ClaudeAccountsController, List<ClaudeAccount>>(
      ClaudeAccountsController.new,
    );

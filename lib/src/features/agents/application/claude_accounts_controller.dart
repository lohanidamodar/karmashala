import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../data/claude_account_dao.dart';
import '../data/claude_auth_service.dart';
import '../domain/agent_installation.dart';
import '../domain/claude_account.dart';
import '../domain/claude_auth_snapshot.dart';

/// Repository-layer provider for saved-Claude-account persistence.
final claudeAccountDaoProvider = Provider<ClaudeAccountDao>(
  (ref) => ClaudeAccountDao(ref.watch(databaseProvider)),
);

/// Locates the credential/config files for a Claude installation.
final claudeAuthLocatorProvider = Provider<ClaudeAuthLocator>(
  (ref) => ClaudeAuthLocator(ref.watch(cliStoreLocatorProvider)),
);

/// Reads/captures/switches Claude accounts.
final claudeAuthServiceProvider = Provider<ClaudeAuthService>(
  (ref) => ClaudeAuthService(
    ids: ref.watch(idGeneratorProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// The live logged-in account for one Claude installation, read from disk.
/// Keyed by installation so each Claude install refreshes independently.
final claudeAuthSnapshotProvider =
    FutureProvider.family<ClaudeAuthSnapshot, AgentInstallation>((
      ref,
      installation,
    ) async {
      final environments = ref.watch(executionEnvironmentDaoProvider).getAll();
      final paths = await ref
          .watch(claudeAuthLocatorProvider)
          .pathsFor(installation, environments);
      if (paths == null) {
        return ClaudeAuthSnapshot.signedOut(installation.environmentId);
      }
      return ref.watch(claudeAuthServiceProvider).readSnapshot(paths);
    });

/// Holds the saved Claude accounts and drives capture/switch.
class ClaudeAccountsController extends Notifier<List<ClaudeAccount>> {
  final _logger = AppLogger.named('claude-accounts');

  @override
  List<ClaudeAccount> build() => ref.watch(claudeAccountDaoProvider).getAll();

  /// Captures the account currently logged in to [installation] and saves it.
  /// Returns the saved account. Throws [ClaudeAuthException] on failure.
  Future<ClaudeAccount> captureCurrent(AgentInstallation installation) async {
    final paths = await _pathsFor(installation);
    final account = await ref.read(claudeAuthServiceProvider).capture(paths);
    final dao = ref.read(claudeAccountDaoProvider);
    final saved = dao.upsert(account);
    state = dao.getAll();
    return saved;
  }

  /// Switches [installation] to the saved [account]. Before writing, the account
  /// currently logged in is captured so the user can always switch back.
  Future<void> switchTo(
    AgentInstallation installation,
    ClaudeAccount account,
  ) async {
    final service = ref.read(claudeAuthServiceProvider);
    final dao = ref.read(claudeAccountDaoProvider);
    final paths = await _pathsFor(installation);

    // Snapshot the outgoing account first so switching is always reversible.
    try {
      final current = await service.capture(paths);
      dao.upsert(current);
    } on ClaudeAuthException catch (e) {
      _logger.info(
        'No current account to back up before switch (${e.message}).',
      );
    }

    await service.switchTo(account, paths);
    dao.upsert(account); // refresh denormalized fields / captured env
    state = dao.getAll();
    ref.invalidate(claudeAuthSnapshotProvider(installation));
  }

  /// Forgets a saved account (does not touch any installation's files).
  void forget(ClaudeAccount account) {
    final dao = ref.read(claudeAccountDaoProvider);
    dao.delete(account.id);
    state = dao.getAll();
  }

  Future<ClaudeAuthPaths> _pathsFor(AgentInstallation installation) async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
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

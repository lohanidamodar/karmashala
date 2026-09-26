import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/agent_cli_bridge.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../data/codex_account_dao.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/discovery.dart';

final codexAccountDaoProvider = Provider<CodexAccountDao>(
  (ref) => CodexAccountDao(ref.watch(databaseProvider)),
);

final codexAuthLocatorProvider = Provider<CodexAuthLocator>(
  (ref) => CodexAuthLocator(ref.watch(cliStoreLocatorProvider)),
);

final codexAuthServiceProvider = Provider<CodexAuthService>(
  (ref) => CodexAuthService(
    ids: ref.watch(agentCliIdsProvider),
    clock: ref.watch(agentCliClockProvider),
  ),
);

final codexAuthSnapshotProvider =
    FutureProvider.family<CodexAuthSnapshot, AgentInstallation>((
      ref,
      installation,
    ) async {
      final environments = ref.watch(executionEnvironmentDaoProvider).getAll();
      final location = await ref
          .watch(codexAuthLocatorProvider)
          .locationFor(installation, environments);
      if (location == null) {
        return CodexAuthSnapshot.signedOut(installation.environmentId);
      }
      return ref
          .watch(codexAuthServiceProvider)
          .readSnapshot(
            location.path,
            installation.environmentId,
            io: location.io,
          );
    });

class CodexAccountsController extends Notifier<List<CodexAccount>> {
  @override
  List<CodexAccount> build() => ref.watch(codexAccountDaoProvider).getAll();

  Future<CodexAccount> captureCurrent(AgentInstallation installation) async {
    final location = await _locationFor(installation);
    final account = await ref
        .read(codexAuthServiceProvider)
        .capture(location.path, installation.environmentId, io: location.io);
    final dao = ref.read(codexAccountDaoProvider);
    final saved = dao.upsert(account);
    state = dao.getAll();
    return saved;
  }

  /// Switches the installation after first preserving its outgoing identity.
  Future<void> switchTo(
    AgentInstallation installation,
    CodexAccount account,
  ) async {
    final service = ref.read(codexAuthServiceProvider);
    final dao = ref.read(codexAccountDaoProvider);
    final location = await _locationFor(installation);
    try {
      dao.upsert(
        await service.capture(
          location.path,
          installation.environmentId,
          io: location.io,
        ),
      );
    } on CodexAuthException {
      // A missing outgoing login is valid: the saved account can still be
      // restored into this installation.
    }
    await service.switchTo(account, location.path, io: location.io);
    state = dao.getAll();
    ref.invalidate(codexAuthSnapshotProvider(installation));
  }

  void forget(CodexAccount account) {
    final dao = ref.read(codexAccountDaoProvider);
    dao.delete(account.id);
    state = dao.getAll();
  }

  Future<CodexAuthLocation> _locationFor(AgentInstallation installation) async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
    final location = await ref
        .read(codexAuthLocatorProvider)
        .locationFor(installation, environments);
    if (location == null) {
      throw CodexAuthException(
        'Could not locate Codex auth for ${installation.environmentId}.',
      );
    }
    return location;
  }
}

final codexAccountsControllerProvider =
    NotifierProvider<CodexAccountsController, List<CodexAccount>>(
      CodexAccountsController.new,
    );

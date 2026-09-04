import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../data/codex_account_dao.dart';
import '../data/codex_auth_service.dart';
import '../domain/agent_installation.dart';
import '../domain/codex_account.dart';

final codexAccountDaoProvider = Provider<CodexAccountDao>(
  (ref) => CodexAccountDao(ref.watch(databaseProvider)),
);

final codexAuthLocatorProvider = Provider<CodexAuthLocator>(
  (ref) => CodexAuthLocator(ref.watch(cliStoreLocatorProvider)),
);

final codexAuthServiceProvider = Provider<CodexAuthService>(
  (ref) => CodexAuthService(
    ids: ref.watch(idGeneratorProvider),
    clock: ref.watch(clockProvider),
  ),
);

final codexAuthSnapshotProvider =
    FutureProvider.family<CodexAuthSnapshot, AgentInstallation>((
      ref,
      installation,
    ) async {
      final environments = ref.watch(executionEnvironmentDaoProvider).getAll();
      final path = await ref
          .watch(codexAuthLocatorProvider)
          .authPathFor(installation, environments);
      if (path == null) {
        return CodexAuthSnapshot.signedOut(installation.environmentId);
      }
      return ref
          .watch(codexAuthServiceProvider)
          .readSnapshot(path, installation.environmentId);
    });

class CodexAccountsController extends Notifier<List<CodexAccount>> {
  @override
  List<CodexAccount> build() => ref.watch(codexAccountDaoProvider).getAll();

  Future<CodexAccount> captureCurrent(AgentInstallation installation) async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
    final path = await ref
        .read(codexAuthLocatorProvider)
        .authPathFor(installation, environments);
    if (path == null) {
      throw CodexAuthException(
        'Could not locate Codex auth for ${installation.environmentId}.',
      );
    }
    final account = await ref
        .read(codexAuthServiceProvider)
        .capture(path, installation.environmentId);
    final dao = ref.read(codexAccountDaoProvider);
    final saved = dao.upsert(account);
    state = dao.getAll();
    return saved;
  }

  void forget(CodexAccount account) {
    final dao = ref.read(codexAccountDaoProvider);
    dao.delete(account.id);
    state = dao.getAll();
  }
}

final codexAccountsControllerProvider =
    NotifierProvider<CodexAccountsController, List<CodexAccount>>(
      CodexAccountsController.new,
    );

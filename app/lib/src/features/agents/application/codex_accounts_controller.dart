import 'package:riverpod/riverpod.dart';

import '../../../core/util/agent_cli_bridge.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../data/agents_data.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/discovery.dart';

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
      final environments = ref.watch(environmentsDataProvider).getAll();
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

/// The saved Codex accounts — the server's, **without their credentials**,
/// followed as they change — and capture/switch. The `auth.json` bundle is
/// only ever asked for right before a switch writes it.
class CodexAccountsController extends Notifier<List<CodexAccount>> {
  CodexAccountsData get _data => ref.read(codexAccountsDataProvider);

  @override
  List<CodexAccount> build() {
    final data = ref.watch(codexAccountsDataProvider);
    final accounts = data.getAll();
    final listening = data.changes.listen((_) => state = data.getAll());
    ref.onDispose(listening.cancel);
    return accounts;
  }

  Future<CodexAccount> captureCurrent(AgentInstallation installation) async {
    final location = await _locationFor(installation);
    final account = await ref
        .read(codexAuthServiceProvider)
        .capture(location.path, installation.environmentId, io: location.io);
    final saved = await _data.save(account);
    state = _data.getAll();
    return saved;
  }

  /// Switches the installation after first preserving its outgoing identity.
  Future<void> switchTo(
    AgentInstallation installation,
    CodexAccount account,
  ) async {
    final service = ref.read(codexAuthServiceProvider);
    final location = await _locationFor(installation);
    // The saved sign-in, asked for now and held only for this switch.
    final saved = await _data.credentials(account.id);
    if (saved.auth.isEmpty) {
      throw CodexAuthException(
        'The saved account ${account.email ?? account.accountId} has no '
        'sign-in to switch to.',
      );
    }
    try {
      await _data.save(
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
    await service.switchTo(saved, location.path, io: location.io);
    state = _data.getAll();
    ref.invalidate(codexAuthSnapshotProvider(installation));
  }

  Future<void> forget(CodexAccount account) async {
    await _data.delete(account.id);
    state = _data.getAll();
  }

  Future<CodexAuthLocation> _locationFor(AgentInstallation installation) async {
    final environments = ref.read(environmentsDataProvider).getAll();
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

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../data/agents_data.dart';

/// Who is signed in to one Claude installation now, as the server read it
/// from that installation's own files (or the login Keychain) — identity and
/// expiry, never the token.
final claudeAuthSnapshotProvider =
    FutureProvider.family<ClaudeAuthSnapshot, AgentInstallation>((
      ref,
      installation,
    ) async {
      final signIn = await ref.watch(agentWorkProvider).signIn(installation.id);
      return signIn is AnthropicSignIn
          ? signIn.snapshot
          : ClaudeAuthSnapshot.signedOut(installation.environmentId);
    });

/// The saved Claude accounts — the server's, **without their credentials**,
/// followed as they change — and asking the server to capture or switch.
/// The server does both on its own machine: a token never reaches this app.
class ClaudeAccountsController extends Notifier<List<ClaudeAccount>> {
  @override
  List<ClaudeAccount> build() {
    final data = ref.watch(claudeAccountsDataProvider);
    final listening = data.changes.listen((_) => state = data.getAll());
    ref.onDispose(listening.cancel);
    return data.getAll();
  }

  /// Captures the account signed in to [installation]. Throws
  /// [ClaudeAuthException] with the server's words.
  Future<void> captureCurrent(AgentInstallation installation) =>
      _asked(() => ref.read(agentWorkProvider).capture(installation.id));

  /// Switches [installation] to [account]; the server captures the account
  /// signed in now first, so it can be switched back to.
  Future<void> switchTo(
    AgentInstallation installation,
    ClaudeAccount account,
  ) async {
    await _asked(
      () => ref.read(agentWorkProvider).switchTo(installation.id, account.id),
    );
    ref.invalidate(claudeAuthSnapshotProvider(installation));
  }

  /// Forgets a saved account (no installation's files are touched).
  Future<void> forget(ClaudeAccount account) =>
      ref.read(claudeAccountsDataProvider).delete(account.id);

  static Future<void> _asked(Future<Object?> Function() ask) async {
    try {
      await ask();
    } on DataRefused catch (refusal) {
      throw ClaudeAuthException(refusal.message);
    }
  }
}

final claudeAccountsControllerProvider =
    NotifierProvider<ClaudeAccountsController, List<ClaudeAccount>>(
      ClaudeAccountsController.new,
    );

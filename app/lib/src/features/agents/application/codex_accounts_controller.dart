import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../data/agents_data.dart';

/// Who is signed in to one Codex installation now, as the server read its
/// `auth.json` — identity and expiry, never the token.
final codexAuthSnapshotProvider =
    FutureProvider.family<CodexAuthSnapshot, AgentInstallation>((
      ref,
      installation,
    ) async {
      final signIn = await ref.watch(agentWorkProvider).signIn(installation.id);
      return signIn is OpenAiSignIn
          ? signIn.snapshot
          : CodexAuthSnapshot.signedOut(installation.environmentId);
    });

/// The saved Codex accounts — the server's, **without their credentials**,
/// followed as they change — and asking the server to capture or switch.
class CodexAccountsController extends Notifier<List<CodexAccount>> {
  @override
  List<CodexAccount> build() {
    final data = ref.watch(codexAccountsDataProvider);
    final listening = data.changes.listen((_) => state = data.getAll());
    ref.onDispose(listening.cancel);
    return data.getAll();
  }

  /// Throws [CodexAuthException] with the server's words.
  Future<void> captureCurrent(AgentInstallation installation) =>
      _asked(() => ref.read(agentWorkProvider).capture(installation.id));

  /// Switches the installation; the server keeps its outgoing identity first.
  Future<void> switchTo(
    AgentInstallation installation,
    CodexAccount account,
  ) async {
    await _asked(
      () => ref.read(agentWorkProvider).switchTo(installation.id, account.id),
    );
    ref.invalidate(codexAuthSnapshotProvider(installation));
  }

  Future<void> forget(CodexAccount account) =>
      ref.read(codexAccountsDataProvider).delete(account.id);

  static Future<void> _asked(Future<Object?> Function() ask) async {
    try {
      await ask();
    } on DataRefused catch (refusal) {
      throw CodexAuthException(refusal.message);
    }
  }
}

final codexAccountsControllerProvider =
    NotifierProvider<CodexAccountsController, List<CodexAccount>>(
      CodexAccountsController.new,
    );

part of '../agents_and_accounts_page.dart';

/// A saved account, whichever vendor's store it came from.
@immutable
class _Saved {
  const _Saved({
    required this.id,
    required this.title,
    required this.raw,
    this.email,
    this.plan,
  });

  final String id;
  final String title;
  final String? email;
  final String? plan;
  final Object raw;

  /// "me@example.com · max", as the board writes an account.
  String get describe => plan == null ? title : '$title · $plan';

  /// The menu's "Re-read the sign-in" row, told apart by identity.
  static const reread = _Saved(id: '\u0000reread', title: '', raw: '');

  @override
  bool operator ==(Object other) => other is _Saved && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Who one install is signed in as, and which saved account that is.
class _SignIn {
  const _SignIn({required this.signedIn, this.email, this.plan, this.savedId});

  final bool signedIn;
  final String? email;
  final String? plan;

  /// The saved account it matches, or null when it is signed in to one not
  /// saved yet (which earns the row a Capture).
  final String? savedId;

  String get describe {
    final who = email ?? 'Signed in';
    return plan == null ? who : '$who · $plan';
  }
}

/// **What one agent's account store can do**, so the machines and accounts
/// sections are written once for Claude's OAuth store and Codex's `auth.json`
/// store alike. Null for an agent whose accounts this app does not save.
sealed class _AccountStore {
  const _AccountStore();

  static _AccountStore? of(AgentAdapter? adapter) =>
      switch (adapter?.accounts) {
        AnthropicOAuthAccounts() => const _ClaudeStore(),
        OpenAiAuthFileAccounts() => const _CodexStore(),
        _ => null,
      };

  List<_Saved> saved(WidgetRef ref);
  AsyncValue<_SignIn> signIn(WidgetRef ref, AgentInstallation install);
  void reread(WidgetRef ref, AgentInstallation install);
  Future<void> capture(WidgetRef ref, AgentInstallation install);
  Future<void> switchTo(WidgetRef ref, AgentInstallation install, _Saved to);
  Future<void> forget(WidgetRef ref, _Saved account);
}

final class _ClaudeStore extends _AccountStore {
  const _ClaudeStore();

  @override
  List<_Saved> saved(WidgetRef ref) => [
    for (final account in ref.watch(claudeAccountsControllerProvider))
      _Saved(
        id: account.id,
        title: account.email,
        email: account.email,
        plan: account.subscriptionType,
        raw: account,
      ),
  ];

  @override
  AsyncValue<_SignIn> signIn(WidgetRef ref, AgentInstallation install) {
    final accounts = ref.watch(claudeAccountsControllerProvider);
    return ref
        .watch(claudeAuthSnapshotProvider(install))
        .whenData(
          (s) => _SignIn(
            signedIn: s.isSignedIn,
            email: s.email,
            plan: s.subscriptionType,
            savedId: s.isSignedIn
                ? accounts.where(s.matches).firstOrNull?.id
                : null,
          ),
        );
  }

  @override
  void reread(WidgetRef ref, AgentInstallation install) =>
      ref.invalidate(claudeAuthSnapshotProvider(install));

  @override
  Future<void> capture(WidgetRef ref, AgentInstallation install) => ref
      .read(claudeAccountsControllerProvider.notifier)
      .captureCurrent(install);

  @override
  Future<void> switchTo(WidgetRef ref, AgentInstallation install, _Saved to) =>
      ref
          .read(claudeAccountsControllerProvider.notifier)
          .switchTo(install, to.raw as ClaudeAccount);

  @override
  Future<void> forget(WidgetRef ref, _Saved account) => ref
      .read(claudeAccountsControllerProvider.notifier)
      .forget(account.raw as ClaudeAccount);
}

final class _CodexStore extends _AccountStore {
  const _CodexStore();

  @override
  List<_Saved> saved(WidgetRef ref) => [
    for (final account in ref.watch(codexAccountsControllerProvider))
      _Saved(
        id: account.id,
        title: account.email ?? account.accountId,
        email: account.email,
        plan: account.planType,
        raw: account,
      ),
  ];

  @override
  AsyncValue<_SignIn> signIn(WidgetRef ref, AgentInstallation install) {
    final accounts = ref.watch(codexAccountsControllerProvider);
    return ref
        .watch(codexAuthSnapshotProvider(install))
        .whenData(
          (s) => _SignIn(
            signedIn: s.isSignedIn,
            email: s.email ?? s.accountId,
            plan: s.planType,
            savedId: s.isSignedIn
                ? accounts
                      .where((a) => a.accountId == s.accountId)
                      .firstOrNull
                      ?.id
                : null,
          ),
        );
  }

  @override
  void reread(WidgetRef ref, AgentInstallation install) =>
      ref.invalidate(codexAuthSnapshotProvider(install));

  @override
  Future<void> capture(WidgetRef ref, AgentInstallation install) => ref
      .read(codexAccountsControllerProvider.notifier)
      .captureCurrent(install);

  @override
  Future<void> switchTo(WidgetRef ref, AgentInstallation install, _Saved to) =>
      ref
          .read(codexAccountsControllerProvider.notifier)
          .switchTo(install, to.raw as CodexAccount);

  @override
  Future<void> forget(WidgetRef ref, _Saved account) => ref
      .read(codexAccountsControllerProvider.notifier)
      .forget(account.raw as CodexAccount);
}

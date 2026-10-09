import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import 'agent_providers.dart';
import 'agent_usage_providers.dart';
import 'claude_accounts_controller.dart';
import 'codex_accounts_controller.dart';

/// How one account switch went, kept so whichever usage card now holds the
/// machine can say so: the switched machine moves to the new account's card.
@immutable
class AccountSwitchOutcome {
  const AccountSwitchOutcome({
    required this.installationId,
    required this.agentId,
    required this.environmentId,
    required this.account,
    required this.at,
    this.failure,
  });

  final String installationId;
  final String agentId;
  final String environmentId;

  /// The saved account switched to, as a person reads it.
  final String account;
  final DateTime at;

  /// The server's words when it refused; null when the switch went through.
  final String? failure;

  bool get succeeded => failure == null;
}

/// A switch the server refused, in its words.
class AccountSwitchFailed implements Exception {
  const AccountSwitchFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

@immutable
class AccountSwitchState {
  const AccountSwitchState({this.busy = const {}, this.last});

  /// The installations a switch is under way on.
  final Set<String> busy;
  final AccountSwitchOutcome? last;
}

/// **The one account switch** every surface asks — the usage card's machine
/// rows and Settings alike. It outlives the widget that asked, so a card that
/// closes or rebuilds mid-switch neither loses the switch nor its outcome.
class AccountSwitchController extends Notifier<AccountSwitchState> {
  @override
  AccountSwitchState build() => const AccountSwitchState();

  /// Signs [installation] in as the saved account [accountId], then asks for
  /// the machine's usage reading so the toolbar moves with it. Never throws:
  /// a refusal is the outcome's [AccountSwitchOutcome.failure].
  Future<AccountSwitchOutcome> switchTo(
    AgentInstallation installation,
    String accountId,
  ) async {
    state = AccountSwitchState(
      busy: {...state.busy, installation.id},
      last: state.last,
    );
    var label = accountId;
    String? failure;
    try {
      final kind = ref
          .read(agentRegistryProvider)
          .adapterFor(installation.agentId)
          ?.accounts;
      switch (kind) {
        case AnthropicOAuthAccounts():
          final account = ref
              .read(claudeAccountsControllerProvider)
              .where((a) => a.id == accountId)
              .firstOrNull;
          if (account == null) throw const AccountSwitchFailed(_notSaved);
          label = account.email;
          await ref
              .read(claudeAccountsControllerProvider.notifier)
              .switchTo(installation, account);
        case OpenAiAuthFileAccounts():
          final account = ref
              .read(codexAccountsControllerProvider)
              .where((a) => a.id == accountId)
              .firstOrNull;
          if (account == null) throw const AccountSwitchFailed(_notSaved);
          label = account.email ?? account.accountId;
          await ref
              .read(codexAccountsControllerProvider.notifier)
              .switchTo(installation, account);
        default:
          throw const AccountSwitchFailed(
            'This agent\'s sign-in cannot be switched here.',
          );
      }
      // A new sign-in is a new quota. The reading's own failure is the
      // Refresh button's to report, not the switch's.
      await ref
          .read(usageReadingsProvider)
          .refresh(usageAccountKey(installation))
          .catchError((Object _) {});
    } on ClaudeAuthException catch (e) {
      failure = e.message;
    } on CodexAuthException catch (e) {
      failure = e.message;
    } on AccountSwitchFailed catch (e) {
      failure = e.message;
    } catch (e) {
      failure = '$e';
    }
    final outcome = AccountSwitchOutcome(
      installationId: installation.id,
      agentId: installation.agentId,
      environmentId: installation.environmentId,
      account: label,
      at: ref.read(clockProvider).nowUtc(),
      failure: failure,
    );
    state = AccountSwitchState(
      busy: {...state.busy}..remove(installation.id),
      last: outcome,
    );
    return outcome;
  }

  /// Forgets the last outcome, so a card opened later does not repeat it.
  void dismiss() {
    if (state.last == null) return;
    state = AccountSwitchState(busy: state.busy);
  }

  static const _notSaved = 'That account is no longer saved.';
}

final accountSwitchControllerProvider =
    NotifierProvider<AccountSwitchController, AccountSwitchState>(
      AccountSwitchController.new,
    );

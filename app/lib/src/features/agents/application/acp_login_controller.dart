import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../env_secrets/application/env_secrets_controller.dart';
import '../data/agents_data.dart';

/// The login method remembered for one ACP installation, as the server keeps
/// it; null when none was chosen. ACP v1 names methods, never accounts.
final acpAuthStateProvider = FutureProvider.autoDispose
    .family<AcpAuthState?, String>(
      (ref, installationId) =>
          ref.watch(agentWorkProvider).acpAuthState(installationId),
    );

/// The auth methods one ACP installation advertises, read by the server over
/// a short-lived connection to it.
final acpAuthMethodsProvider = FutureProvider.autoDispose
    .family<AcpAuthMethods, String>(
      (ref, installationId) =>
          ref.watch(agentWorkProvider).acpAuthMethods(installationId),
    );

/// Logging in to an ACP agent, as a person asks it: each answers the
/// sentence to show, and throws [DataRefused] in the server's words.
class AcpLoginActions {
  AcpLoginActions(this._ref);

  final Ref _ref;

  /// Logs [installationId] in with [method]: an API key is kept in the
  /// server's vault under the variable the method reads first; a terminal
  /// method opens a terminal tab; any other is the agent's `authenticate`.
  Future<String> logIn(
    String installationId,
    AcpAuthMethod method, {
    String? apiKey,
  }) async {
    final work = _ref.read(agentWorkProvider);
    final variable = method.apiKeyVariable;
    if (variable != null && apiKey != null && apiKey.isNotEmpty) {
      await _ref.read(envVariablesProvider.notifier).set(variable, apiKey);
    }
    try {
      if (method.terminal) {
        await work.acpTerminalLogin(installationId, method.id);
        return 'A terminal tab is running ${method.name}. Finish the login '
            'there.';
      }
      await work.acpAuthenticate(installationId, method.id);
      return 'Logged in via ${method.name}.';
    } finally {
      _ref.invalidate(acpAuthStateProvider(installationId));
    }
  }

  /// Forgets the remembered method; [logout] asks the agent to end its login
  /// too, where it offers that.
  Future<void> forget(String installationId, {bool logout = false}) async {
    try {
      await _ref
          .read(agentWorkProvider)
          .acpAuthClear(installationId, logout: logout);
    } finally {
      _ref.invalidate(acpAuthStateProvider(installationId));
    }
  }
}

final acpLoginActionsProvider = Provider<AcpLoginActions>(AcpLoginActions.new);

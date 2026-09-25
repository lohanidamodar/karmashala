import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/launch.dart';
import '../../environments/application/environment_providers.dart';
import 'claude_accounts_controller.dart';
import 'agent_providers.dart';

/// Whether an interactive Claude login exists for [installation] — presence and
/// expiry, never the token. `false` for anything that could not be read, so a
/// launch only ever withholds on evidence.
final claudeLoginPresentProvider =
    FutureProvider.family<bool, AgentInstallation>((ref, installation) async {
      final environments = ref.watch(executionEnvironmentDaoProvider).getAll();
      final paths = await ref
          .watch(claudeAuthLocatorProvider)
          .pathsFor(installation, environments);
      if (paths == null) return false;
      return ref.watch(claudeAuthServiceProvider).hasUsableLogin(paths);
    });

/// What one launch decided about the Anthropic credential variables it would
/// otherwise have handed on from the user's shell.
///
/// [settingsEnvironment] is Karmashala's own overlay, which wins: a name the
/// env-variable settings supply is never removed, so the settings page and the
/// child process cannot disagree.
final inheritedCredentialDecisionProvider =
    Provider<
      Future<InheritedCredentialDecision> Function(
        AgentInstallation, {
        required bool inheritsHostEnvironment,
        required Map<String, String> settingsEnvironment,
      })
    >(
      (ref) =>
          (
            installation, {
            required bool inheritsHostEnvironment,
            required Map<String, String> settingsEnvironment,
          }) async {
            // Only an agent signing in through Anthropic's OAuth login reads
            // these, and only a pane that inherits *this* host's environment can
            // be changed by removing something from it — a WSL or SSH child is
            // handed a different environment entirely.
            if (!inheritsHostEnvironment) {
              return InheritedCredentialDecision.none;
            }
            final accounts = ref
                .read(agentRegistryProvider)
                .adapterFor(installation.agentId)
                ?.accounts;
            if (accounts is! AnthropicOAuthAccounts) {
              return InheritedCredentialDecision.none;
            }
            final hostEnvironment = ref.read(hostEnvironmentProvider);
            final wouldInherit = accounts.inheritedCredentialVariables.any(
              (name) => (hostEnvironment[name] ?? '').trim().isNotEmpty,
            );
            // Nothing to decide, so nothing is read off disk and no Keychain is
            // asked: the common case costs one map lookup.
            if (!wouldInherit) return InheritedCredentialDecision.none;
            return decideInheritedCredentials(
              hostEnvironment: hostEnvironment,
              settingsEnvironment: settingsEnvironment,
              hasUsableLogin: await ref.read(
                claudeLoginPresentProvider(installation).future,
              ),
            );
          },
    );

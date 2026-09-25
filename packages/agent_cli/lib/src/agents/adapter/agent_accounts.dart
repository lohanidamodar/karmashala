import '../domain/anthropic_credential_env.dart';

/// **Which account switching the app offers for an agent**, named by the
/// sign-in mechanism rather than the agent: another CLI signing in the same
/// way is offered the same switcher.
sealed class AgentAccounts {
  const AgentAccounts();
}

/// Signed in through Anthropic's OAuth login (`claudeAiOauth`), which the
/// Anthropic credential variables in a shell's environment override.
final class AnthropicOAuthAccounts extends AgentAccounts {
  const AnthropicOAuthAccounts();

  /// The environment variables that, handed on from the user's shell, win over
  /// the stored login — see `decideInheritedCredentials`.
  Set<String> get inheritedCredentialVariables => anthropicCredentialVariables;
}

/// Signed in through an OpenAI `auth.json` in the store home.
final class OpenAiAuthFileAccounts extends AgentAccounts {
  const OpenAiAuthFileAccounts();
}

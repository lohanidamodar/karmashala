import '../domain/env_variable.dart';

/// The variables that apply to one launch, as a plain environment map.
///
/// Pure, and resolved **once per launch** — never per keystroke. The terminal's
/// hot path is `terminal.onOutput` → `_pty.write`, and nothing here is on it.
///
/// [environmentId] and [projectId] are what the narrower scopes would match.
/// Neither is offered in the UI yet, so today every enabled variable is
/// [EnvVarScope.all] and both arguments are ignored in practice; they are here
/// so adding the picker later is a UI change rather than a plumbing change.
Map<String, String> resolveEnvOverlay(
  EnvVaultData vault, {
  String? environmentId,
  String? projectId,
}) {
  if (!vault.enabled) return const {};
  final overlay = <String, String>{};
  for (final variable in vault.variables) {
    if (!variable.enabled) continue;
    final applies = switch (variable.scope) {
      EnvVarScope.all => true,
      EnvVarScope.environment =>
        variable.scopeId != null && variable.scopeId == environmentId,
      EnvVarScope.project =>
        variable.scopeId != null && variable.scopeId == projectId,
    };
    if (!applies) continue;
    // A later record wins a name collision, which is also the order the
    // settings list shows: the one further down is the one in force.
    overlay[variable.name] = variable.value;
  }
  return overlay;
}

/// The values the log redactor should never let through, whatever they are
/// called.
///
/// Only [EnvVariable.secret] values, and only those long enough to be worth a
/// pattern: a two-character value would match half the words in a log line and
/// turn the log into `[redacted:env-secret]` soup. Six is the same floor the
/// shipped `named secret` rule uses for the value half of an assignment.
Set<String> redactableSecretValues(EnvVaultData vault) => {
  for (final variable in vault.variables)
    if (variable.secret && variable.value.length >= 6) variable.value,
};

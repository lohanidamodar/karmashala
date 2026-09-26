import '../domain/env_variable.dart';

/// The variables that apply to one launch, as a plain environment map. Pure,
/// and resolved once per launch — nothing here is on the terminal's hot path.
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

/// The values the log redactor must never let through. Only secrets, and only
/// those long enough to be worth a pattern — six, or the log is redaction soup.
Set<String> redactableSecretValues(EnvVaultData vault) => {
  for (final variable in vault.variables)
    if (variable.secret && variable.value.length >= 6) variable.value,
};

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../data/env_vault.dart';
import '../domain/env_variable.dart';
import 'env_overlay.dart';

/// The vault backing this session.
///
/// Defaults to [EnvVault.unavailable] rather than throwing the way
/// `databaseProvider` does. "No vault" is a legitimate state — it is what every
/// test that does not care about environment variables should see, and what a
/// machine whose vault could not be opened must fall back to — and the one
/// thing this feature may never do is stop a terminal opening. `main.dart`
/// overrides it with the real, hardened one.
final envVaultProvider = Provider<EnvVault>((ref) => EnvVault.unavailable());

/// The user's environment variables, and the master switch over them.
class EnvSecretsController extends Notifier<EnvVaultData> {
  @override
  EnvVaultData build() {
    final data = ref.watch(envVaultProvider).data;
    _publishRedaction(data);
    return data;
  }

  /// Re-reads the vault from disk. Used by the settings page's retry.
  Future<void> reload() async {
    final data = await ref.read(envVaultProvider).load();
    _apply(data);
  }

  Future<void> setEnabled(bool enabled) =>
      _save(state.copyWith(enabled: enabled));

  /// Adds a variable. Throws [EnvVaultRefusal] when the vault will not take it.
  Future<void> add({
    required String name,
    required String value,
    required bool secret,
  }) => _save(
    state.copyWith(
      variables: [
        ...state.variables,
        EnvVariable(
          id: ref.read(idGeneratorProvider).newId(),
          name: name.trim(),
          value: value,
          secret: secret,
          updatedAt: ref.read(clockProvider).nowUtc(),
        ),
      ],
    ),
  );

  /// Replaces the name, value and secrecy of [id].
  ///
  /// [value] is null when the user edited a secret's name without replacing its
  /// value — the dialog cannot show them what is there, so "leave it alone" has
  /// to be expressible.
  Future<void> update(
    String id, {
    String? name,
    String? value,
    bool? secret,
  }) => _save(
    state.copyWith(
      variables: [
        for (final variable in state.variables)
          if (variable.id == id)
            variable.copyWith(
              name: name?.trim(),
              value: value,
              secret: secret,
              updatedAt: ref.read(clockProvider).nowUtc(),
            )
          else
            variable,
      ],
    ),
  );

  Future<void> setVariableEnabled(String id, bool enabled) => _save(
    state.copyWith(
      variables: [
        for (final variable in state.variables)
          if (variable.id == id)
            variable.copyWith(
              enabled: enabled,
              updatedAt: ref.read(clockProvider).nowUtc(),
            )
          else
            variable,
      ],
    ),
  );

  Future<void> remove(String id) => _save(
    state.copyWith(
      variables: [
        for (final variable in state.variables)
          if (variable.id != id) variable,
      ],
    ),
  );

  Future<void> _save(EnvVaultData next) async {
    _apply(await ref.read(envVaultProvider).save(next));
  }

  void _apply(EnvVaultData data) {
    state = data;
    _publishRedaction(data);
  }

  /// Teaches the log redactor this session's secret values.
  ///
  /// Belt and braces. Nothing in the app logs a `PtyLaunch.environment` map and
  /// a test pins that it stays that way — but a value that reaches a log line
  /// by a route nobody predicted (an error message quoting a command, a
  /// third-party exception) must not reach the log file, the panel or the
  /// clipboard. Redaction runs once on the way into `Diagnostics`, so installing
  /// it here covers all four sinks at once.
  void _publishRedaction(EnvVaultData data) {
    final rule = RedactionRule.literalValues(
      redactableSecretValues(data),
      name: 'environment secret',
      replacement: '[redacted:env-secret]',
    );
    Diagnostics.instance.redactor.extraRules = rule == null ? const [] : [rule];
  }
}

final envSecretsControllerProvider =
    NotifierProvider<EnvSecretsController, EnvVaultData>(
      EnvSecretsController.new,
    );

/// The environment overlay every terminal launch layers onto the host
/// environment.
///
/// Read (not watched) at launch by `terminalInstanceFactoryProvider`. Changing
/// a variable therefore affects the *next* pane rather than the ones already
/// running, which is what the settings page says it does.
final terminalEnvOverlayProvider = Provider<Map<String, String>>(
  (ref) => resolveEnvOverlay(ref.watch(envSecretsControllerProvider)),
);

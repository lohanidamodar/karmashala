import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../data/env_vault.dart';
import '../domain/env_variable.dart';
import 'env_overlay.dart';

/// The vault backing this session. Defaults to [EnvVault.unavailable] rather
/// than throwing: no vault is legitimate, and this must never stop a terminal.
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

  /// Replaces the name, value and secrecy of [id]. [value] is null when the user
  /// edited a secret's name only — "leave it alone" has to be expressible.
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

  /// Teaches the log redactor this session's secret values. Belt and braces: a
  /// value reaching a log line by an unpredicted route must still not get out.
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

/// The environment overlay every terminal launch layers on. Read, not watched:
/// a change affects the *next* pane, which is what the settings page says.
final terminalEnvOverlayProvider = Provider<Map<String, String>>(
  (ref) => resolveEnvOverlay(ref.watch(envSecretsControllerProvider)),
);

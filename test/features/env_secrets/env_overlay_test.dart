import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/logging/log_redactor.dart';
import 'package:karmashala/src/features/env_secrets/application/env_overlay.dart';
import 'package:karmashala/src/features/env_secrets/domain/env_variable.dart';

EnvVariable _variable({
  String id = 'v1',
  String name = 'TOKEN',
  String value = 'value-one',
  bool secret = true,
  bool enabled = true,
  EnvVarScope scope = EnvVarScope.all,
  String? scopeId,
}) => EnvVariable(
  id: id,
  name: name,
  value: value,
  secret: secret,
  enabled: enabled,
  scope: scope,
  scopeId: scopeId,
  updatedAt: DateTime.utc(2026),
);

void main() {
  group('resolveEnvOverlay', () {
    test('an enabled all-scope variable is injected', () {
      final overlay = resolveEnvOverlay(
        EnvVaultData(variables: [_variable()]),
      );
      expect(overlay, {'TOKEN': 'value-one'});
    });

    test('the master switch off injects nothing at all', () {
      final overlay = resolveEnvOverlay(
        EnvVaultData(enabled: false, variables: [_variable()]),
      );
      expect(overlay, isEmpty);
    });

    test('a variable switched off is kept but not injected', () {
      final overlay = resolveEnvOverlay(
        EnvVaultData(variables: [_variable(enabled: false)]),
      );
      expect(overlay, isEmpty);
    });

    test('a narrower scope only applies to its own target', () {
      final vault = EnvVaultData(
        variables: [
          _variable(
            id: 'v2',
            name: 'ONLY_WSL',
            scope: EnvVarScope.environment,
            scopeId: 'wsl:ubuntu',
          ),
        ],
      );

      expect(resolveEnvOverlay(vault), isEmpty);
      expect(
        resolveEnvOverlay(vault, environmentId: 'wsl:ubuntu'),
        {'ONLY_WSL': 'value-one'},
      );
      expect(resolveEnvOverlay(vault, environmentId: 'windows'), isEmpty);
    });

    test('a later record wins a name collision', () {
      final overlay = resolveEnvOverlay(
        EnvVaultData(
          variables: [
            _variable(id: 'a', value: 'first'),
            _variable(id: 'b', value: 'second'),
          ],
        ),
      );
      expect(overlay, {'TOKEN': 'second'});
    });
  });

  group('redactableSecretValues', () {
    test('only secrets, and only ones long enough to be a safe pattern', () {
      final values = redactableSecretValues(
        EnvVaultData(
          variables: [
            _variable(id: 'a', value: 'long-enough-secret'),
            _variable(id: 'b', name: 'SHORT', value: 'abc'),
            _variable(
              id: 'c',
              name: 'EDITOR',
              value: 'nvim-not-a-secret',
              secret: false,
            ),
          ],
        ),
      );
      expect(values, {'long-enough-secret'});
    });
  });

  group('the redactor rule built from those values', () {
    test('replaces a secret nothing else would have caught', () {
      // `ACME_PAT` contains none of the shipped rule's keywords, which is
      // exactly the gap this rule exists to close.
      final redactor = LogRedactor()
        ..extraRules = [
          RedactionRule.literalValues(
            {'hunter2-hunter2'},
            name: 'environment secret',
            replacement: '[redacted:env-secret]',
          )!,
        ];

      expect(
        redactor.apply('ACME_PAT was hunter2-hunter2 at launch'),
        'ACME_PAT was [redacted:env-secret] at launch',
      );
    });

    test('is null when there is nothing to redact', () {
      expect(
        RedactionRule.literalValues(
          const {},
          name: 'environment secret',
          replacement: '[redacted:env-secret]',
        ),
        isNull,
      );
    });

    test('escapes regex metacharacters in a value', () {
      final rule = RedactionRule.literalValues(
        {r'a+b(c)[d].*'},
        name: 'environment secret',
        replacement: '[redacted:env-secret]',
      )!;

      expect(rule.apply(r'token=a+b(c)[d].*'), 'token=[redacted:env-secret]');
      expect(rule.apply('token=aaabbb'), 'token=aaabbb');
    });

    test('a longer secret containing a shorter one is replaced whole', () {
      final rule = RedactionRule.literalValues(
        {'abcdef', 'abcdef-with-more'},
        name: 'environment secret',
        replacement: '[X]',
      )!;

      expect(rule.apply('v=abcdef-with-more'), 'v=[X]');
    });

    test('a redactor with no extra rules is unchanged', () {
      expect(LogRedactor().apply('nothing to see'), 'nothing to see');
    });
  });
}

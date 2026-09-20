import 'package:agent_cli/launch.dart';
import 'package:test/test.dart';

/// Stands in for a real key in every case below. Nothing under test may put it
/// — or any part of it — anywhere a person or a log file can see.
const _key = 'sk-ant-the-value-nothing-may-print';

InheritedCredentialDecision _decide({
  Map<String, String> host = const {},
  Map<String, String> settings = const {},
  bool hasUsableLogin = true,
}) => decideInheritedCredentials(
  hostEnvironment: host,
  settingsEnvironment: settings,
  hasUsableLogin: hasUsableLogin,
);

void main() {
  group('a shell that exports a key', () {
    test('loses it when the CLI is signed in', () {
      final decision = _decide(host: {'ANTHROPIC_API_KEY': _key});

      expect(decision.removed, {'ANTHROPIC_API_KEY'});
      expect(decision.changedEnvironment, isTrue);
      expect(decision.removedBilling, isTrue);
    });

    test('keeps it when there is no login to fall back on', () {
      final decision = _decide(
        host: {'ANTHROPIC_API_KEY': _key},
        hasUsableLogin: false,
      );

      expect(decision.removed, isEmpty);
      expect(decision.keptWithoutLogin, isTrue);
      expect(decision.changedEnvironment, isFalse);
    });

    test('loses every one of the three at once', () {
      final decision = _decide(
        host: {
          'ANTHROPIC_API_KEY': _key,
          'ANTHROPIC_AUTH_TOKEN': _key,
          'CLAUDE_CODE_OAUTH_TOKEN': _key,
        },
      );

      expect(decision.removed, anthropicCredentialVariables);
    });

    test('an empty value is not a credential and nothing happens', () {
      final decision = _decide(host: {'ANTHROPIC_API_KEY': '   '});

      expect(decision.inherited, isEmpty);
      expect(decision.changedEnvironment, isFalse);
      expect(decision.logSummary, 'none');
    });
  });

  group('a deliberate provider keeps its credentials', () {
    for (final override in const {
      'CLAUDE_CODE_USE_BEDROCK': '1',
      'CLAUDE_CODE_USE_VERTEX': 'true',
      'CLAUDE_CODE_USE_FOUNDRY': '1',
      'CLAUDE_CODE_USE_MANTLE': '1',
      'ANTHROPIC_BASE_URL': 'https://gateway.example.test/v1',
      'ANTHROPIC_VERTEX_BASE_URL': 'https://vertex.example.test',
      'ANTHROPIC_BEDROCK_BASE_URL': 'https://bedrock.example.test',
      'ANTHROPIC_FOUNDRY_BASE_URL': 'https://foundry.example.test',
      // Not a provider, but it moves the credentials file we look for, so a
      // "signed out" reading stops being evidence.
      'CLAUDE_CONFIG_DIR': '/somewhere/else',
    }.entries) {
      test('${override.key} exempts the launch', () {
        final decision = _decide(
          host: {'ANTHROPIC_API_KEY': _key, override.key: override.value},
        );

        expect(decision.removed, isEmpty);
        expect(decision.keptForOverride, override.key);
      });
    }

    test('a provider switched off buys no exemption', () {
      for (final off in const ['0', 'false', '', '  ']) {
        final decision = _decide(
          host: {'ANTHROPIC_API_KEY': _key, 'CLAUDE_CODE_USE_BEDROCK': off},
        );

        expect(
          decision.removed,
          {'ANTHROPIC_API_KEY'},
          reason: 'CLAUDE_CODE_USE_BEDROCK=$off is not a Bedrock setup',
        );
      }
    });

    test('an override set in Karmashala counts like one in the shell', () {
      final decision = _decide(
        host: {'ANTHROPIC_API_KEY': _key},
        settings: {'ANTHROPIC_BASE_URL': 'https://gateway.example.test/v1'},
      );

      expect(decision.removed, isEmpty);
      expect(decision.keptForOverride, 'ANTHROPIC_BASE_URL');
    });
  });

  group('a Karmashala setting outranks the shell', () {
    test('a name the settings supply is never removed', () {
      final decision = _decide(
        host: {'ANTHROPIC_API_KEY': _key},
        settings: {'ANTHROPIC_API_KEY': 'the-one-settings-shows'},
      );

      expect(
        decision.removed,
        isEmpty,
        reason: 'Settings would otherwise describe a child that got nothing',
      );
      expect(decision.keptBySetting, {'ANTHROPIC_API_KEY'});
    });

    test('and its neighbour is still stripped', () {
      final decision = _decide(
        host: {'ANTHROPIC_API_KEY': _key, 'ANTHROPIC_AUTH_TOKEN': _key},
        settings: {'ANTHROPIC_API_KEY': 'the-one-settings-shows'},
      );

      expect(decision.removed, {'ANTHROPIC_AUTH_TOKEN'});
    });
  });

  group('nothing says the secret out loud', () {
    test('not the log line, in any outcome', () {
      for (final decision in [
        _decide(host: {'ANTHROPIC_API_KEY': _key}),
        _decide(host: {'ANTHROPIC_API_KEY': _key}, hasUsableLogin: false),
        _decide(
          host: {'ANTHROPIC_API_KEY': _key, 'CLAUDE_CODE_USE_BEDROCK': '1'},
        ),
        _decide(host: {'ANTHROPIC_API_KEY': _key}, settings: {
          'ANTHROPIC_API_KEY': _key,
        }),
      ]) {
        expect(decision.logSummary, isNot(contains(_key)));
        expect(decision.logSummary, isNot(contains('sk-ant')));
        expect(decision.logSummary, contains('ANTHROPIC_API_KEY'));
      }
    });

    test('not the notice, and not its length either', () {
      final notice = inheritedCredentialNotice(
        _decide(host: {'ANTHROPIC_API_KEY': _key}),
      );

      expect(notice, isNot(contains(_key)));
      expect(notice, isNot(contains('sk-ant')));
      expect(notice, isNot(contains('${_key.length}')));
      expect(notice, contains('ANTHROPIC_API_KEY'));
      expect(notice, contains('billed'));
    });

    test('and no value is carried on the decision at all', () {
      final decision = _decide(host: {'ANTHROPIC_API_KEY': _key});

      expect('${decision.inherited}${decision.removed}', isNot(contains(_key)));
    });
  });

  group('what the notice says depends on what was taken', () {
    test('the subscription token is not described as a bill', () {
      final notice = inheritedCredentialNotice(
        _decide(host: {'CLAUDE_CODE_OAUTH_TOKEN': _key}),
      );

      expect(notice, contains('CLAUDE_CODE_OAUTH_TOKEN'));
      expect(
        notice,
        isNot(contains('billed')),
        reason: 'CLAUDE_CODE_OAUTH_TOKEN is a subscription token',
      );
    });

    test('it names both when both went', () {
      final notice = inheritedCredentialNotice(
        _decide(
          host: {'ANTHROPIC_API_KEY': _key, 'ANTHROPIC_AUTH_TOKEN': _key},
        ),
      );

      expect(notice, contains('ANTHROPIC_API_KEY'));
      expect(notice, contains('ANTHROPIC_AUTH_TOKEN'));
      expect(notice, contains('they were'));
    });
  });
}

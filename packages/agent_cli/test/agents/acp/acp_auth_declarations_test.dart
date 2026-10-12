import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// How each shipped ACP agent's logins complete, as its descriptor records
/// them: every note carries where it was read, a terminal login of the
/// agent's own is declared only where one was seen, and choosing a method
/// keeps everything else the spec says.
void main() {
  AcpLaunchSpec specOf(String id) => AgentRegistry.builtIn.adapterFor(id)!.acp!;

  test('every completion and terminal login names its evidence', () {
    for (final id in ['antigravity-acp', 'grok', 'codex-acp', 'claude-acp']) {
      final spec = specOf(id);
      for (final completion in spec.authCompletions.values) {
        expect(completion.how, isNotEmpty, reason: id);
        expect(completion.evidence, contains('2026-10-12'), reason: id);
      }
      final own = spec.terminalLogin;
      if (own != null) expect(own.evidence, contains('2026-10-12'));
    }
  });

  test('what each agent declares, read off it on 2026-10-12', () {
    expect(specOf('antigravity-acp').authCompletions.keys, [
      'oauth-personal',
      'oauth-business',
      'gemini-api-key',
    ]);
    expect(specOf('antigravity-acp').terminalLogin, isNull);
    expect(specOf('grok').authCompletions.keys, ['grok.com']);
    expect(specOf('grok').terminalLogin!.arguments, ['login', '--device-auth']);
    expect(specOf('codex-acp').authCompletions.keys, ['chatgpt']);
    expect(specOf('codex-acp').terminalLogin!.arguments, [
      'login',
      '--device-auth',
    ]);
    expect(specOf('claude-acp').authCompletions.keys, ['claude-login']);
    expect(specOf('claude-acp').terminalLogin, isNull);
  });

  test('choosing a method keeps the rest of the spec, versioned arguments '
      'included', () {
    final spec = specOf('claude-acp');
    final chosen = spec.withAuthMethod('claude-login');
    expect(chosen.authMethodId, 'claude-login');
    expect(chosen.versionedArguments, spec.versionedArguments);
    expect(chosen.authCompletions, spec.authCompletions);
    expect(
      chosen.argumentsFor(linux: false, version: '2.1.300'),
      spec.argumentsFor(linux: false, version: '2.1.300'),
    );
    final grok = specOf('grok').withAuthMethod('grok.com');
    expect(grok.terminalLogin, specOf('grok').terminalLogin);
  });
}

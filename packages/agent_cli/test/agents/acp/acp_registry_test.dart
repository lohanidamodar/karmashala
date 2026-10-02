import 'dart:io';

import 'package:agent_cli/src/agents/acp/acp_registry.dart';
import 'package:test/test.dart';

void main() {
  final fixture = File(
    'test/agents/acp/fixtures/registry.json',
  ).readAsStringSync();

  group('AcpRegistryCatalog.parse', () {
    final catalog = AcpRegistryCatalog.parse(fixture);

    test('keeps every object entry and drops the rest', () {
      // Five objects in the fixture; the bare string is not an entry.
      expect(catalog.agents, hasLength(5));
      expect(catalog.agents.map((a) => a.id), [
        'claude-acp',
        'gemini',
        'native-agent',
        'sparse',
        null,
      ]);
    });

    test('an npx entry', () {
      final claude = catalog.byId('claude-acp')!;
      expect(claude.name, 'Claude Agent');
      expect(claude.version, '0.85.1');
      expect(claude.description, 'Claude Code over ACP.');
      expect(
        claude.npx!.package,
        '@agentclientprotocol/claude-agent-acp@0.85.1',
      );
      expect(claude.npx!.args, isEmpty);
      expect(claude.binaries, isEmpty);
      expect(claude.icon, 'https://cdn.example.test/registry/claude-acp.svg');

      final gemini = catalog.byId('gemini')!;
      expect(gemini.npx!.args, ['--acp']);
      expect(gemini.npx!.env, {'GEMINI_ACP': '1'});
      // An entry that names no icon is drawn with a glyph, not guessed at.
      expect(gemini.icon, isNull);
    });

    test(
      'a binary entry, with both command spellings and unknown platforms',
      () {
        final native = catalog.byId('native-agent')!;
        expect(native.npx, isNull);
        expect(native.binaries.keys, [
          'darwin-aarch64',
          'windows-x86_64',
          'plan9-mips',
        ]);
        final darwin = native.binaries['darwin-aarch64']!;
        expect(darwin.command, 'native-agent');
        expect(darwin.args, ['--stdio']);
        expect(darwin.sha256, '0a1b');
        expect(darwin.archive, endsWith('darwin-aarch64.tar.gz'));
        expect(native.binaries['windows-x86_64']!.command, 'native-agent.exe');
        final plan9 = native.binaries['plan9-mips']!;
        expect(plan9.command, isNull);
        expect(plan9.sha256, isNull);
        expect(plan9.args, isEmpty);
      },
    );

    test('missing fields read as null, never as a guess', () {
      final sparse = catalog.byId('sparse')!;
      expect(sparse.name, isNull);
      expect(sparse.version, isNull);
      expect(sparse.description, isNull);
      expect(sparse.npx, isNull);
      expect(sparse.binaries, isEmpty);
      expect(sparse.label, 'sparse');

      final anonymous = catalog.agents.last;
      expect(anonymous.id, isNull);
      expect(anonymous.label, 'No id at all');
      expect(anonymous.npx!.package, isNull);
    });

    test('no agents list is an empty catalog; a non-object is refused', () {
      expect(AcpRegistryCatalog.parse('{"version": 1}').agents, isEmpty);
      expect(AcpRegistryCatalog.parse('{"agents": 7}').agents, isEmpty);
      expect(
        () => AcpRegistryCatalog.parse('[1, 2]'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AcpRegistryCatalog.parse('not json'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('launchFor', () {
    final catalog = AcpRegistryCatalog.parse(fixture);

    test('prefers npx wherever the entry has one', () {
      final gemini = catalog.byId('gemini')!.launchFor('windows-x86_64')!;
      expect(gemini.command, 'npx');
      expect(gemini.args, ['-y', '@google/gemini-cli@0.62.0', '--acp']);
    });

    test('falls back to the platform binary, and to nothing', () {
      final native = catalog.byId('native-agent')!;
      final darwin = native.launchFor('darwin-aarch64')!;
      expect(darwin.command, 'native-agent');
      expect(darwin.args, ['--stdio']);
      expect(native.launchFor('linux-x86_64'), isNull);
      // A platform entry with no command is not launchable.
      expect(native.launchFor('plan9-mips'), isNull);
      // An npx block without a package is not npx.
      expect(catalog.agents.last.launchFor('linux-x86_64'), isNull);
    });
  });

  test('fetch asks the injected getter for the published URL, once', () async {
    final asked = <Uri>[];
    final catalog = await AcpRegistryCatalog.fetch((url) async {
      asked.add(url);
      return fixture;
    });
    expect(asked, [Uri.parse(AcpRegistryCatalog.registryUrl)]);
    expect(
      AcpRegistryCatalog.registryUrl,
      'https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json',
    );
    expect(catalog.byId('claude-acp'), isNotNull);
  });
}

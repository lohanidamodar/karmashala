import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_host/src/agents/agent_folder_trust.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A folder Karmashala made for a session without a project is marked
/// trusted in the agent's own settings before the agent starts there, so the
/// agent does not ask about a folder that was empty a moment ago. Claude Code
/// keeps trust per git root in `~/.claude.json`; Codex per folder in
/// `~/.codex/config.toml`. A choice already recorded is never overwritten.
void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('ks-trust'));
  tearDown(() => home.deleteSync(recursive: true));

  String claudeStore() {
    final store = Directory(p.join(home.path, '.claude'))..createSync();
    return store.path;
  }

  String codexStore() {
    final store = Directory(p.join(home.path, '.codex'))..createSync();
    return store.path;
  }

  File claudeJson() => File(p.join(home.path, '.claude.json'));
  File codexToml() => File(p.join(home.path, '.codex', 'config.toml'));

  AgentFolderTrust trust(Map<String, String> homes) => AgentFolderTrust(
    storeHome: (environmentId, agentId) async => homes[agentId],
  );

  const wslFolder = EnvironmentPath(
    environmentId: 'wsl:arch',
    path: '/home/me/karmashala/scratch/2026-10-03-new-session-a1b2c3',
  );
  const windowsFolder = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\Users\me\karmashala\scratch\2026-10-03-new-session-a1b2c3',
  );

  group('Claude Code', () {
    test('a new folder is added to projects as trusted, beside the store, the '
        'rest of the file left as it was', () async {
      final store = claudeStore();
      const before =
          '{\n  "numStartups": 3,\n  "projects": {\n    "/home/me/app": {\n'
          '      "allowedTools": [],\n      "hasTrustDialogAccepted": true\n'
          '    }\n  },\n  "theme": "dark"\n}';
      claudeJson().writeAsStringSync(before);

      final marked = await trust({AgentIds.claudeCode: store}).trust(
        agentId: AgentIds.claudeCode,
        folder: wslFolder,
        windowsAgent: false,
      );

      expect(marked, isTrue);
      final after = claudeJson().readAsStringSync();
      expect(after, startsWith('{\n  "numStartups": 3,\n  "projects": '));
      expect(after, endsWith(',\n  "theme": "dark"\n}'));
      final projects =
          (jsonDecode(after) as Map<String, Object?>)['projects']!
              as Map<String, Object?>;
      expect(
        (projects['/home/me/app']! as Map)['hasTrustDialogAccepted'],
        isTrue,
      );
      final added = projects[wslFolder.path]! as Map<String, Object?>;
      expect(added['hasTrustDialogAccepted'], isTrue);
      expect(added['allowedTools'], isEmpty);
      expect(File('${claudeJson().path}.karmashala-tmp').existsSync(), isFalse);
    });

    test(
      'a folder on Windows is keyed the way Claude Code spells it',
      () async {
        final store = claudeStore();
        claudeJson().writeAsStringSync('{"projects": {}}');

        await trust({AgentIds.claudeCode: store}).trust(
          agentId: AgentIds.claudeCode,
          folder: windowsFolder,
          windowsAgent: true,
        );

        final projects =
            (jsonDecode(claudeJson().readAsStringSync())
                    as Map<String, Object?>)['projects']!
                as Map<String, Object?>;
        expect(projects.keys, [
          'C:/Users/me/karmashala/scratch/2026-10-03-new-session-a1b2c3',
        ]);
      },
    );

    test('an entry already there keeps its fields and gains the flag; one '
        'already trusted is not rewritten', () async {
      final store = claudeStore();
      claudeJson().writeAsStringSync(
        jsonEncode({
          'projects': {
            wslFolder.path: {
              'allowedTools': ['Bash'],
              'hasTrustDialogAccepted': false,
            },
          },
        }),
      );
      final folderTrust = trust({AgentIds.claudeCode: store});

      expect(
        await folderTrust.trust(
          agentId: AgentIds.claudeCode,
          folder: wslFolder,
          windowsAgent: false,
        ),
        isTrue,
      );
      final entry =
          ((jsonDecode(claudeJson().readAsStringSync())
                      as Map<String, Object?>)['projects']!
                  as Map<String, Object?>)[wslFolder.path]!
              as Map<String, Object?>;
      expect(entry['allowedTools'], ['Bash']);
      expect(entry['hasTrustDialogAccepted'], isTrue);

      final written = claudeJson().lastModifiedSync();
      final again = claudeJson().readAsStringSync();
      expect(
        await folderTrust.trust(
          agentId: AgentIds.claudeCode,
          folder: wslFolder,
          windowsAgent: false,
        ),
        isTrue,
      );
      expect(claudeJson().readAsStringSync(), again);
      expect(claudeJson().lastModifiedSync(), written);
    });

    test('no settings file yet means Claude Code never ran here: nothing is '
        'written', () async {
      final store = claudeStore();
      expect(
        await trust({AgentIds.claudeCode: store}).trust(
          agentId: AgentIds.claudeCode,
          folder: wslFolder,
          windowsAgent: false,
        ),
        isFalse,
      );
      expect(claudeJson().existsSync(), isFalse);
    });

    test('a file that is not JSON is left alone', () async {
      final store = claudeStore();
      claudeJson().writeAsStringSync('not json');
      expect(
        await trust({AgentIds.claudeCode: store}).trust(
          agentId: AgentIds.claudeCode,
          folder: wslFolder,
          windowsAgent: false,
        ),
        isFalse,
      );
      expect(claudeJson().readAsStringSync(), 'not json');
    });
  });

  group('Codex', () {
    test('a table marking the folder trusted is appended, once', () async {
      final store = codexStore();
      codexToml().writeAsStringSync('model = "gpt-5"\n');
      final folderTrust = trust({AgentIds.codex: store});

      expect(
        await folderTrust.trust(
          agentId: AgentIds.codex,
          folder: wslFolder,
          windowsAgent: false,
        ),
        isTrue,
      );
      await folderTrust.trust(
        agentId: AgentIds.codex,
        folder: wslFolder,
        windowsAgent: false,
      );

      expect(
        codexToml().readAsStringSync(),
        'model = "gpt-5"\n\n'
        '[projects."${wslFolder.path}"]\n'
        'trust_level = "trusted"\n',
      );
    });

    test('a folder already in the file keeps the choice there', () async {
      final store = codexStore();
      final before =
          '[projects."${wslFolder.path}"]\ntrust_level = "untrusted"\n';
      codexToml().writeAsStringSync(before);

      expect(
        await trust({AgentIds.codex: store}).trust(
          agentId: AgentIds.codex,
          folder: wslFolder,
          windowsAgent: false,
        ),
        isTrue,
      );
      expect(codexToml().readAsStringSync(), before);
    });

    test('on Windows the folder is keyed as Codex writes it, and a missing '
        'config is made', () async {
      final store = codexStore();

      await trust({AgentIds.codex: store}).trust(
        agentId: AgentIds.codex,
        folder: windowsFolder,
        windowsAgent: true,
      );

      expect(
        codexToml().readAsStringSync(),
        "[projects.'c:\\users\\me\\karmashala\\scratch\\"
        "2026-10-03-new-session-a1b2c3']\n"
        'trust_level = "trusted"\n',
      );
    });
  });

  test(
    'another agent, or one with no store on that machine, is not touched',
    () async {
      expect(
        await trust({}).trust(
          agentId: AgentIds.codex,
          folder: wslFolder,
          windowsAgent: false,
        ),
        isFalse,
      );
      expect(
        await trust({
          'grok': home.path,
        }).trust(agentId: 'grok', folder: wslFolder, windowsAgent: false),
        isFalse,
      );
      expect(home.listSync(), isEmpty);
    },
  );
}

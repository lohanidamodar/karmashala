import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_context_readings.dart';
import 'package:agent_cli/context.dart';

/// The shape Claude Code really keeps on disk, measured 2026-09-13 against
/// ~/.claude.json: `mcpServers` at the top, one entry per directory under
/// `projects`, each with its own servers and approval lists.
const _claudeSpec = AgentMcpConfigSpec.json(
  projectFileName: '.mcp.json',
  projectServersPath: ['mcpServers'],
  userFileName: '../.claude.json',
  userServersPath: ['mcpServers'],
  perProjectKey: 'projects',
  perProjectServersPath: ['mcpServers'],
  approvedKey: 'enabledMcpjsonServers',
  refusedKey: 'disabledMcpjsonServers',
  evidence: 'test',
);

void main() {
  group('mcpServersFrom', () {
    test('reads all three scopes and names the file each came from', () {
      final entries = mcpServersFrom(
        _claudeSpec,
        const AgentConfigSources(
          directory: '/home/d/work',
          projectConfig: {
            'mcpServers': {
              'dart': {'type': 'stdio'},
            },
          },
          projectConfigPath: '/home/d/work/.mcp.json',
          userConfig: {
            'mcpServers': {
              'grafana': {'type': 'stdio'},
            },
            'projects': {
              '/home/d/work': {
                'mcpServers': {
                  'appwrite': {'type': 'stdio'},
                },
                'enabledMcpjsonServers': ['dart'],
              },
            },
          },
          userConfigPath: '.claude.json',
        ),
      );

      expect(entries.map((e) => '${e.name}:${e.origin.name}'), [
        'dart:project',
        'appwrite:directory',
        'grafana:user',
      ]);
      expect(entries.first.source, '/home/d/work/.mcp.json');
      expect(entries.last.source, '.claude.json');
    });

    test(
      'a project server the user has not answered is not claimed as given',
      () {
        final entries = mcpServersFrom(
          _claudeSpec,
          const AgentConfigSources(
            directory: '/home/d/work',
            projectConfig: {
              'mcpServers': {
                'dart': {'type': 'stdio'},
                'other': {'type': 'stdio'},
              },
            },
            userConfig: {
              'projects': {
                '/home/d/work': {
                  'disabledMcpjsonServers': ['other'],
                },
              },
            },
          ),
        );

        expect(
          {for (final e in entries) e.name: e.standing},
          {
            'dart': AgentContextStanding.awaitingApproval,
            'other': AgentContextStanding.refused,
          },
        );
      },
    );

    test('per-directory servers are read for this directory only', () {
      final entries = mcpServersFrom(
        _claudeSpec,
        const AgentConfigSources(
          directory: '/home/d/work',
          userConfig: {
            'projects': {
              '/home/d/elsewhere': {
                'mcpServers': {
                  'appwrite': {'type': 'stdio'},
                },
              },
            },
          },
        ),
      );

      expect(entries, isEmpty);
    });

    test('an undeclared agent reads as nothing but what the app injects', () {
      final entries = mcpServersFrom(
        const AgentMcpConfigSpec.undeclared(refusal: 'it keeps TOML'),
        const AgentConfigSources(
          directory: '/home/d/work',
          // Even with a file in hand: an undeclared agent's file is not this
          // one, and reading it anyway would be a guess.
          userConfig: {
            'mcpServers': {
              'grafana': {'type': 'stdio'},
            },
          },
        ),
        injectsOwnServer: true,
      );

      expect(entries.single.name, kKarmashalaMcpServerName);
      expect(entries.single.origin, AgentContextOrigin.karmashala);
    });

    test('Karmashala marks its own entry rather than looking configured', () {
      final entries = mcpServersFrom(
        _claudeSpec,
        const AgentConfigSources(directory: '/home/d/work'),
        injectsOwnServer: true,
      );

      expect(entries.single.origin, AgentContextOrigin.karmashala);
      expect(entries.single.source, isEmpty);
    });

    test('a server credential never reaches a row', () {
      final entries = mcpServersFrom(
        _claudeSpec,
        const AgentConfigSources(
          directory: '/home/d/work',
          userConfig: {
            'mcpServers': {
              'grafana': {
                'type': 'stdio',
                'command': '/home/d/.local/bin/mcp-grafana',
                'env': {'GRAFANA_SERVICE_ACCOUNT_TOKEN': 'glsa_secret'},
              },
            },
          },
        ),
      );

      expect(entries.single.detail, 'stdio');
      expect('${entries.single}', isNot(contains('glsa_secret')));
    });
  });

  group('describeProvenance', () {
    test("the app's own entries say so rather than reading as configured", () {
      expect(
        describeProvenance(
          const AgentContextEntry(
            name: 'karmashala',
            origin: AgentContextOrigin.karmashala,
            source: '',
          ),
        ),
        'added by Karmashala at launch',
      );
      expect(
        describeProvenance(
          const AgentContextEntry(
            name: 'karmashala-instructions',
            origin: AgentContextOrigin.karmashala,
            source: '~/.claude/skills',
          ),
        ),
        contains('installed by Karmashala'),
      );
    });

    test('everything else names the file the user would edit', () {
      expect(
        describeProvenance(
          const AgentContextEntry(
            name: 'grafana',
            origin: AgentContextOrigin.user,
            source: '.claude.json',
          ),
        ),
        '.claude.json',
      );
      expect(
        describeProvenance(
          const AgentContextEntry(
            name: 'dart',
            origin: AgentContextOrigin.project,
            source: '.mcp.json',
            standing: AgentContextStanding.awaitingApproval,
          ),
        ),
        '.mcp.json · in this checkout · you have not approved it yet',
      );
    });
  });

  group('skillDescriptionIn', () {
    test('reads the folded scalar our own skills are written with', () {
      const skill = KarmashalaSkill(
        name: 'karmashala-instructions',
        description: 'Use when about to call a Karmashala tool.',
        body: 'body',
      );

      expect(
        skillDescriptionIn(skill.render()),
        'Use when about to call a Karmashala tool.',
      );
    });

    test('reads a plain inline description', () {
      expect(
        skillDescriptionIn(
          '---\nname: a\ndescription: does a thing\n---\nbody',
        ),
        'does a thing',
      );
    });

    test('a file with no frontmatter declares nothing', () {
      expect(skillDescriptionIn('# just markdown'), isNull);
    });
  });
}

import 'dart:convert';

import 'package:karmashala_core/logging.dart';
import 'package:test/test.dart';

// Every value here is made up, spelled the way the real thing is.
const kGrafana = 'glsa_FAKE0token0for0tests0only0aBcDeF_12345678';
const kAws = 'AKIAFAKEFAKEFAKE1234';
const kOpenAiProject = 'sk-proj-FAKE_token-for-tests-0123456789';
const kSlack = 'xoxb-1234-FAKE-tokenfortests';
const kGithub = 'ghp_FAKEtokenFORtests0123456789abcd';
const kXai = 'xai-FAKEtokenFORtests0123456789';
const kPlain = 'FAKE_TOKEN_123_plain_value';

void main() {
  group('AgentRedactor.text', () {
    test('masks each known token shape', () {
      for (final token in [
        kGrafana,
        kAws,
        kOpenAiProject,
        kSlack,
        kGithub,
        kXai,
      ]) {
        final out = AgentRedactor.text('using $token now');
        expect(out, isNot(contains(token)), reason: token);
        expect(out, startsWith('using '));
      }
    });

    test('masks named secrets in JSON and env assignments', () {
      final json = AgentRedactor.text(
        '{"GRAFANA_API_KEY":"$kPlain","SLACK_BOT_TOKEN": "$kPlain"}',
      );
      expect(json, isNot(contains(kPlain)));
      expect(json, contains('"GRAFANA_API_KEY":"[redacted]"'));
      expect(AgentRedactor.text('MY_SECRET=$kPlain'), 'MY_SECRET=[redacted]');
      expect(
        AgentRedactor.text('export DB_PASSWORD="$kPlain"'),
        'export DB_PASSWORD="[redacted]"',
      );
    });

    test('masks every value of an env or headers block printed as JSON', () {
      final out = AgentRedactor.text(
        'servers_updated {"name":"g","env":{"PLAIN":"$kPlain","X":"y2"},'
        '"headers":[{"name":"X-Api","value":"$kPlain"}],"command":"mcp-g"}',
      );
      expect(out, isNot(contains(kPlain)));
      expect(out, isNot(contains('"y2"')));
      expect(out, contains('"PLAIN":"[redacted]"'));
      expect(out, contains('"name":"X-Api"'));
      expect(out, contains('"command":"mcp-g"'));
      expect(AgentRedactor.text(out), out);
    });

    test('leaves counts and ordinary words alone', () {
      const lines = [
        '{"max_tokens": 4096, "inputTokens": 1200}',
        'tokens: 5000 of 200000 used',
        'Open https://example.com/device and enter code ABCD-EFGH',
      ];
      for (final line in lines) {
        expect(AgentRedactor.text(line), line);
      }
    });

    test('is idempotent and cuts a long payload', () {
      final once = AgentRedactor.text('token=$kPlain $kGrafana');
      expect(AgentRedactor.text(once), once);
      final long = AgentRedactor.text('x' * 5000, limit: 100);
      expect(long, startsWith('x' * 100));
      expect(long, endsWith('[4900 more chars]'));
    });
  });

  group('AgentRedactor.json', () {
    test('drops env values from an MCP server config, keeping the names', () {
      final config = {
        'mcpServers': [
          {
            'name': 'grafana',
            'command': 'mcp-grafana',
            'args': ['--url', 'https://grafana.example.com'],
            'env': [
              {'name': 'GRAFANA_URL', 'value': 'https://grafana.example.com'},
              {'name': 'GRAFANA_API_KEY', 'value': kPlain},
            ],
          },
          {
            'name': 'other',
            'command': 'x',
            'env': {'ANY_NAME': kPlain},
            'headers': [
              {'name': 'Authorization', 'value': 'Bearer $kPlain'},
            ],
          },
        ],
      };
      final out = jsonEncode(AgentRedactor.json(config));
      expect(out, isNot(contains(kPlain)));
      expect(out, contains('GRAFANA_API_KEY'));
      expect(out, contains('ANY_NAME'));
      expect(out, contains('mcp-grafana'));
    });

    test('masks fields named as secrets, but not links or counts', () {
      final out =
          AgentRedactor.json({
                'accessToken': kPlain,
                'nested': {'client_secret': kPlain, 'password': 12345678},
                'authorizationUrl': 'https://example.com/login',
                'totalTokens': 42,
                'message': 'key $kGithub here',
              })
              as Map<String, Object?>;
      expect(out['accessToken'], AgentRedactor.masked);
      expect(jsonEncode(out['nested']), isNot(contains(kPlain)));
      expect(jsonEncode(out['nested']), isNot(contains('12345678')));
      expect(out['authorizationUrl'], 'https://example.com/login');
      expect(out['totalTokens'], 42);
      expect(out['message'], isNot(contains(kGithub)));
    });
  });

  test('an unhandled message is named by method and size only', () {
    final said = AgentRedactor.unhandled('_x.ai/mcp/servers_updated', {
      'env': {'GRAFANA_API_KEY': kPlain},
    });
    expect(said, startsWith('_x.ai/mcp/servers_updated ('));
    expect(said, endsWith(' bytes)'));
    expect(said, isNot(contains(kPlain)));
    expect(said, isNot(contains('GRAFANA')));
  });
}

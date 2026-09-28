import 'dart:convert';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_installation.dart';
import 'package:agent_cli/src/cli_detection/data/cli_store.dart';
import 'package:agent_cli/src/environments/environment_kind.dart';
import 'package:agent_cli/src/environments/environment_path.dart';
import 'package:agent_cli/src/environments/execution_environment.dart';
import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/usage.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import '../support/fake_http_client.dart';
import '../support/fakes.dart';

/// Usage for an installation on an SSH host is read from that host's own
/// files, through the same locator the Accounts page uses. The "remote" is a
/// map in memory answering the probe and read scripts; every token is made up.
void main() {
  final sshEnvironment = ExecutionEnvironment(
    id: 'ssh:box',
    kind: EnvironmentKind.ssh,
    name: 'do-box',
    sshHostId: 'box',
    createdAt: DateTime.utc(2026),
  );

  AgentInstallation installation(String agentId) => AgentInstallation(
    id: '$agentId@ssh:box',
    agentId: agentId,
    executable: EnvironmentPath(
      environmentId: 'ssh:box',
      path: '/usr/local/bin/$agentId',
    ),
    createdAt: DateTime.utc(2026),
  );

  FakeCommandRunner remote(
    Map<String, String> files, {
    String probe = 'karmashala-home=/home/dev\n',
  }) => FakeCommandRunner(
    environmentId: 'ssh:box',
    responder: (request) {
      if (request.executable == 'bash') {
        return CommandResult(exitCode: 0, stdout: probe, stderr: '');
      }
      expect(request.arguments[1], RemoteAuthFileIo.readScript);
      final text = files[request.arguments[3]];
      return text == null
          ? const CommandResult(exitCode: 3, stdout: '', stderr: '')
          : CommandResult(
              exitCode: 0,
              stdout: '${RemoteAuthFileIo.readMarker}\n$text',
              stderr: '',
            );
    },
  );

  List<String> pathsRead(FakeCommandRunner runner) => [
    for (final request in runner.requests)
      if (request.executable == 'sh') request.arguments[3],
  ];

  AgentUsageService serviceOver(CommandRunner runner, FakeHttpClient http) =>
      AgentUsageService(
        // No local store at all: the old lookup refused here with "Could not
        // locate the store".
        storeLocator: CliStoreLocator(
          runnerFor: (_) => runner,
          environment: const {},
        ),
        clock: FixedClock(DateTime.utc(2026, 7, 28, 12)),
        httpClientFactory: () => http,
        // A Mac host, to show an SSH store never reaches for this Keychain.
        hostIsMacOS: true,
        keychain: ClaudeKeychainCache(
          read: () async => fail('the Keychain was asked about an SSH host'),
        ),
      );

  test('Claude usage on an SSH host reads the remote files and carries the '
      'remote email', () async {
    final runner = remote({
      '/home/dev/.claude/.credentials.json': jsonEncode({
        'claudeAiOauth': {'accessToken': 'SYNTHETIC-remote-token'},
      }),
      '/home/dev/.claude.json': jsonEncode({
        'oauthAccount': {'emailAddress': 'dev@example.test'},
      }),
    });
    final http = FakeHttpClient(body: '{"five_hour": {"utilization": 42.0}}');

    final usage = await serviceOver(
      runner,
      http,
    ).fetch(installation(AgentIds.claudeCode), [sshEnvironment]);

    expect(usage.email, 'dev@example.test');
    expect(usage.windows.single.percent, 42.0);
    expect(http.sentAuthorization, ['Bearer SYNTHETIC-remote-token']);
    expect(
      pathsRead(runner),
      unorderedEquals([
        '/home/dev/.claude.json',
        '/home/dev/.claude/.credentials.json',
      ]),
    );
  });

  test('CLAUDE_CONFIG_DIR on the host moves the files usage reads', () async {
    final runner = remote(
      {
        '/srv/claude-conf/.credentials.json': jsonEncode({
          'claudeAiOauth': {'accessToken': 'SYNTHETIC-moved-token'},
        }),
        '/srv/claude-conf/.claude.json': jsonEncode({
          'oauthAccount': {'emailAddress': 'moved@example.test'},
        }),
      },
      probe: 'karmashala-home=/home/dev\nkarmashala-claude=/srv/claude-conf\n',
    );
    final usage = await serviceOver(
      runner,
      FakeHttpClient(body: '{}'),
    ).fetch(installation(AgentIds.claudeCode), [sshEnvironment]);
    expect(usage.email, 'moved@example.test');
  });

  test('Codex usage on an SSH host reads the remote auth.json', () async {
    final runner = remote({
      '/home/dev/.codex/auth.json': jsonEncode({
        'tokens': {'access_token': 'SYNTHETIC-codex-token'},
      }),
    });
    final http = FakeHttpClient(
      body: jsonEncode({
        'email': 'codex@example.test',
        'rate_limit': {
          'primary_window': {'used_percent': 7},
        },
      }),
    );

    final usage = await serviceOver(
      runner,
      http,
    ).fetch(installation(AgentIds.codex), [sshEnvironment]);

    expect(usage.email, 'codex@example.test');
    expect(usage.windows.single.percent, 7);
    expect(http.sentAuthorization, ['Bearer SYNTHETIC-codex-token']);
    expect(pathsRead(runner), ['/home/dev/.codex/auth.json']);
  });

  test(
    'an unreachable host is named, not reported as a missing store',
    () async {
      final runner = FakeCommandRunner(
        environmentId: 'ssh:box',
        throwError: CommandException('connection refused'),
      );
      final http = FakeHttpClient();

      await expectLater(
        serviceOver(
          runner,
          http,
        ).fetch(installation(AgentIds.claudeCode), [sshEnvironment]),
        throwsA(
          isA<UsageException>()
              .having((e) => e.kind, 'kind', UsageFailureKind.auth)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('do-box'), contains('connection refused')),
              ),
        ),
      );
      expect(http.requests, 0);
    },
  );
}

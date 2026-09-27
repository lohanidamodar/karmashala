import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/read.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/agents/server_agent_work.dart';
import 'package:karmashala_host/src/mcp/tools/project_folders.dart';
import 'package:karmashala_host/src/mcp/tools/project_tool_set.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../agents/agent_work_support.dart';
import 'repo_tool_fixture.dart';

/// An agent's `project_add` imports the CLI history its new checkouts hold —
/// the wiring `serve` makes (`ProjectFolders.onRecorded` →
/// `ServerImports.checkoutsRecorded`), over a Claude Code store in a
/// temporary home.
void main() {
  late RepoToolFixture fixture;
  late Directory home;
  late ServerAgentWork work;
  late ProjectToolSet tools;

  void writeClaudeSession(String cwd, String sessionId) {
    File(
        p.join(
          home.path,
          '.claude',
          'projects',
          claudeStoreDirectoryName(cwd),
          '$sessionId.jsonl',
        ),
      )
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '${jsonEncode({
          'type': 'user',
          'cwd': cwd,
          'sessionId': sessionId,
          'timestamp': '2026-09-25T10:00:00.000Z',
          'message': {'role': 'user', 'content': 'fix the flaky test'},
        })}\n',
      );
  }

  setUp(() {
    fixture = RepoToolFixture();
    home = Directory(
      Directory.systemTemp
          .createTempSync('ks-project-add-home')
          .resolveSymbolicLinksSync(),
    );
    final clock = MutableClock(RepoToolFixture.now);
    work = ServerAgentWork(
      data: fixture.data,
      clock: clock,
      ids: CountingIds('imp'),
      hostEnvironment: {'HOME': home.path, 'USERPROFILE': home.path},
      usageService: (_) => ScriptedUsageService(
        clock: clock,
        answer: (_) => throw UsageException('not in this test'),
      ),
      onItsOwn: false,
    )..attach();
    tools = ProjectToolSet(
      fixture.context,
      reach: fixture.reach,
      folders: ProjectFolders(
        fixture.context,
        fixture.reach,
        onRecorded: work.imports.checkoutsRecorded,
      ),
    );
  });
  tearDown(() {
    work.stop();
    fixture.dispose();
    home.deleteSync(recursive: true);
  });

  test('a project an agent adds brings its CLI history with it', () async {
    final folder = fixture.path('sample-app');
    Directory(folder).createSync(recursive: true);
    writeClaudeSession(folder, 'sess-1');
    writeClaudeSession(p.join(home.path, 'elsewhere'), 'sess-2');

    final answer = await RepoToolFixture.outcome(
      tools.call('project_add', {'path': folder}, null),
    );
    expect(answer.error, isNull);

    final imported = fixture.data
        .open((_) {})
        .handle(const SessionsList())
        .value
        .imported;
    expect([for (final r in imported) r.externalId], ['sess-1']);
    expect(imported.single.environmentId, isNotEmpty);
  });
}

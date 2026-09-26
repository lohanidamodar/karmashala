import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_host/src/sessions/launched_attribution.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

import 'sync_fixture.dart';

/// Learning which conversation a session **we launched** is on, for an agent
/// that takes no id (Codex) — at the server (slice 2b; moved from the app's
/// `LaunchedSessionAttributionService`). Without it the row names no
/// conversation: the tab keeps its placeholder, the imported history stays
/// beside it, and the inbox finds it not active.
void main() {
  late SyncFixture world;

  const conversation = '01a05c73-912d-7bf3-84cc-a1bb591134aa';
  const other = '019a0c34-2cc6-7002-bc5b-3184f3b7332f';

  setUp(() => world = SyncFixture());
  tearDown(() => world.close());

  void insert({
    String id = 's1',
    String installation = 'a2',
    String? externalId,
    String? directory = repoPath,
    SessionStatus status = SessionStatus.running,
    Duration launchOffset = Duration.zero,
  }) => world.insert(
    sessionRow(
      id: id,
      installation: installation,
      externalId: externalId,
      directory: directory,
      status: status,
      launchOffset: launchOffset,
      paneId: 'pane-$id',
    ),
  );

  DetectedSession codex(
    String id, {
    String cwd = repoPath,
    Duration startOffset = const Duration(seconds: 5),
    bool dated = true,
    String cli = AgentIds.codex,
    String environmentId = 'windows',
  }) => storeSession(
    id,
    cli: cli,
    cwd: cwd,
    environmentId: environmentId,
    title: 'a name Codex chose',
    startedAt: dated ? launchedAt.add(startOffset) : null,
  );

  LaunchedAttribution subject() => LaunchedAttribution(rows: world.rows);

  test('a launched Codex row learns the conversation it started', () {
    insert();
    final attribution = subject();

    expect(attribution.wantsStoreSweep, isTrue);
    expect(attribution.attribute([codex(conversation)]), 1);
    expect(world.row('s1')!.externalSessionId, conversation);
    // Told to every client as the row.
    expect(world.toldRows, ['s1']);
    // And having learned it, the row stops costing a scan.
    expect(attribution.wantsStoreSweep, isFalse);
  });

  test('a conversation already running when we launched is not ours', () {
    insert();
    final attribution = subject();
    expect(
      attribution.attribute([
        codex(conversation, startOffset: const Duration(minutes: -30)),
      ]),
      0,
    );
    expect(world.row('s1')!.externalSessionId, isNull);
    expect(attribution.reasonFor('s1'), isNotNull);
  });

  test('a conversation that started long after the launch is not ours', () {
    insert();
    expect(
      subject().attribute([
        codex(conversation, startOffset: const Duration(hours: 2)),
      ]),
      0,
    );
  });

  test('a conversation in another directory is not ours', () {
    insert();
    expect(
      subject().attribute([codex(conversation, cwd: r'C:\src\demo\other')]),
      0,
    );
  });

  test('the same folder seen from WSL is the same folder', () {
    insert();
    expect(
      subject().attribute([
        codex(
          conversation,
          environmentId: 'wsl:Ubuntu',
          cwd: '/mnt/c/src/demo/app',
        ),
      ]),
      1,
    );
    expect(world.row('s1')!.externalSessionId, conversation);
  });

  test('a conversation another row already holds is never taken twice', () {
    insert(id: 's0', externalId: conversation);
    insert(id: 's1');
    expect(subject().attribute([codex(conversation)]), 0);
    expect(world.row('s1')!.externalSessionId, isNull);
  });

  test('two conversations in the window is a refusal, not a coin toss', () {
    insert();
    final attribution = subject();
    expect(
      attribution.attribute([
        codex(conversation),
        codex(other, startOffset: const Duration(seconds: 20)),
      ]),
      0,
    );
    expect(attribution.reasonFor('s1'), contains('2'));
  });

  test('two sessions waiting in one directory refuse together', () {
    insert(id: 's1');
    insert(id: 's2', launchOffset: const Duration(seconds: 2));
    final attribution = subject();
    expect(attribution.attribute([codex(conversation)]), 0);
    expect(world.row('s1')!.externalSessionId, isNull);
    expect(world.row('s2')!.externalSessionId, isNull);
    expect(attribution.reasonFor('s1'), isNotNull);
    expect(attribution.reasonFor('s2'), isNotNull);
  });

  test('an agent that takes --session-id is never a candidate', () {
    insert(installation: 'a1');
    final attribution = subject();
    expect(attribution.wantsStoreSweep, isFalse);
    expect(
      attribution.attribute([codex(conversation, cli: AgentIds.claudeCode)]),
      0,
    );
  });

  test('an agent with its own directory attribution is left to it', () {
    insert(installation: 'a3');
    expect(subject().wantsStoreSweep, isFalse);
  });

  test('a store that cannot say when a conversation began is not matched', () {
    insert();
    expect(subject().attribute([codex(conversation, dated: false)]), 0);
    expect(world.row('s1')!.externalSessionId, isNull);
  });

  test('a stopped session buys no scan', () {
    insert(status: SessionStatus.completed);
    expect(subject().wantsStoreSweep, isFalse);
  });

  test('a row that already has an id buys no scan', () {
    insert(externalId: conversation);
    final attribution = subject();
    expect(attribution.wantsStoreSweep, isFalse);
    expect(attribution.attribute([codex(other)]), 0);
  });

  test('a row with no directory of its own falls back to its checkout', () {
    insert(directory: null);
    expect(subject().attribute([codex(conversation)]), 1);
    expect(world.row('s1')!.externalSessionId, conversation);
  });
}

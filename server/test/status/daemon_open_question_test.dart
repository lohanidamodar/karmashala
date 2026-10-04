import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// **A question the host kept no hook for is read off the agent's record.**
/// The host keeps a question only while the hook that opened it is the
/// status's word: a probe has no hooks, and a screen that moved after the hook
/// makes the grid the word. Found live on 2026-10-04 (Claude Code 2.1.287 in a
/// host-run pane): the chat drew no options, and an answer would have been
/// refused as "already answered".
void main() {
  late AppDatabase database;
  late SessionRegistry registry;
  late DaemonAgentStatus status;
  late DaemonPromptAnswers prompts;

  const fruit = AgentQuestionSet(
    toolUseId: 'toolu_1',
    questions: [
      AgentQuestion(
        question: 'Pick a fruit',
        options: [
          AgentQuestionOption(label: 'Apple'),
          AgentQuestionOption(label: 'Banana'),
        ],
      ),
    ],
  );

  setUp(() {
    database = AppDatabase.memory();
    registry = SessionRegistry(launcher: FakePtyLauncher());
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    prompts = DaemonPromptAnswers(status: status, database: database);
  });

  tearDown(() async {
    await status.close();
    await registry.shutdown();
    database.close();
  });

  test('with no hook question, the record is read', () async {
    final asked = <String>[];
    prompts.readQuestion = (sessionId) async {
      asked.add(sessionId);
      return fruit;
    };
    final open = await prompts.openQuestion('s1');
    expect(open?.toolUseId, 'toolu_1');
    expect(asked, ['s1']);
  });

  test('with no reader, there is still none', () async {
    expect(await prompts.openQuestion('s1'), isNull);
  });
}

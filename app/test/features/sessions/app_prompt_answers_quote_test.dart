import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_session/events.dart';

/// The project-MCP checklist's rows as Claude Code 2.1.287 draws them, as the
/// host's grid source quotes them: blank rows dropped.
const _quoted = [
  '  2 new MCP servers found in this project',
  '  Select any you wish to enable.',
  '  MCP servers may execute code or access system resources. All tool calls '
      'require approval. Learn more in the MCP',
  '  documentation.',
  '  ❯ [✔] dart',
  '    [✔] marionette',
  '       Enable selected',
  ' Space to select · Esc to reject all',
];

class _Terminals implements PromptTerminals {
  List<String>? pane;
  List<String> evidence = _quoted;
  AgentActivityStatus status = AgentActivityStatus.awaitingApproval;

  @override
  bool exists(String sessionId) => true;

  @override
  AgentDescriptor? agentOf(String sessionId) =>
      AgentRegistry.builtIn.byId(AgentIds.claudeCode);

  @override
  AgentStatusReport? statusOf(String sessionId) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: sessionId,
    status: status,
    source: AgentStatusSource.terminalGrid,
    observedAt: DateTime.utc(2026, 10, 17),
    waiting: AgentWaitKind.approval,
    evidence: evidence,
  );

  @override
  List<String>? screen(String sessionId) => pane;

  @override
  bool press(String sessionId, String keys) => false;

  @override
  Future<AgentQuestionSet?> openQuestion(String sessionId) async => null;

  @override
  void record(DecisionRecord decision) {}
}

/// **A session the host runs that no pane of ours shows** — one the board
/// started in the background — has its menu read off the host's status,
/// which quotes the screen: the board offered Approve and Deny on the
/// project-MCP checklist because it read nothing (owner, 2026-10-17).
void main() {
  late _Terminals terminals;
  var hosted = true;

  AppPromptAnswers answers() => AppPromptAnswers(
    local: SessionPromptAnswers(terminals: terminals),
    hostAnswers: (_) => hosted
        ? (request) async =>
              const SessionApprovalAnswer(answered: 'ok', effect: 'ok')
        : null,
    hostChecksAsk: () => true,
  );

  setUp(() {
    terminals = _Terminals();
    hosted = true;
  });

  test('no pane of ours: the checklist the host quotes', () {
    final menu = answers().menuOnScreen('s1')!;
    expect(menu.isChecklist, isTrue);
    expect(menu.options, ['dart', 'marionette', 'Enable selected']);
    expect(menu.prompt.first, '2 new MCP servers found in this project');
    // The id the host's answerer knows that quote by.
    final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
    expect(menu.id, menuQuotedBy(terminals.statusOf('s1'), claude.menus)!.id);
  });

  test('a pane of ours is read, and only it', () {
    terminals.pane = const ['❯ ', '  ⏸ manual mode on · ? for shortcuts'];
    expect(answers().menuOnScreen('s1'), isNull);
  });

  test('a session no host runs answers nowhere, so it offers no menu', () {
    hosted = false;
    expect(answers().menuOnScreen('s1'), isNull);
  });

  test('a status that is no open prompt quotes no menu', () {
    terminals.status = AgentActivityStatus.idle;
    expect(answers().menuOnScreen('s1'), isNull);
  });
}

import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// Which face of Karmashala a chat-card test drives: a terminal CLI in a pane
/// of ours, whose conversation is its own transcript, or an ACP agent, whose
/// conversation is the server's rows.
enum ChatCardSession { terminalCli, acp }

/// One session's chat with [messages] as its record and [status] as its
/// badge, both changeable while the test runs.
class ChatCardHarness {
  ChatCardHarness._(this.container, this._messages, this._status);

  final ProviderContainer container;
  final StreamController<List<TranscriptMessage>> _messages;
  final StreamController<AgentStatusReport> _status;
  AgentStatusReport? _latest;

  static Future<ChatCardHarness> open(
    ChatCardSession kind, {
    required List<TranscriptMessage> messages,
    AgentStatusReport? status,
    List<Override> overrides = const [],
  }) async {
    final agentId = agentIdOf(kind);
    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation(agentId: agentId));
    final dao = db.server.sessionRows
      ..insert(
        Session(
          id: 's1',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Chat cards',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
          externalSessionId: kind == ChatCardSession.terminalCli
              ? 'cli-1'
              : null,
        ),
      );
    // Broadcast with the latest replayed: every watcher sees the same record.
    late final StreamController<List<TranscriptMessage>> records;
    var current = messages;
    records = StreamController<List<TranscriptMessage>>.broadcast();
    late final StreamController<AgentStatusReport> statuses;
    statuses = StreamController<AgentStatusReport>.broadcast();
    late final ChatCardHarness harness;
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        sessionChatTranscriptProvider.overrideWith((ref, id) async* {
          yield current;
          yield* records.stream;
        }),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        agentSessionStatusProvider.overrideWith((ref, id) async* {
          final latest = harness._latest;
          if (latest != null) yield latest;
          yield* statuses.stream;
        }),
        sessionStatusLookupProvider.overrideWithValue((_) => harness._latest),
        ...overrides,
      ],
    );
    harness = ChatCardHarness._(container, records, statuses)
      .._latest = status ?? idle(kind);
    records.stream.listen((next) => current = next);
    if (kind == ChatCardSession.terminalCli) {
      final opened = container
          .read(terminalSessionsControllerProvider.notifier)
          .openAgentTab(
            AgentPaneLaunch(
              agentId: agentId,
              executable: agentId,
              sessionId: 's1',
              title: 'Chat cards',
            ),
          );
      dao.updatePaneId('s1', opened.paneId);
    }
    return harness;
  }

  static String agentIdOf(ChatCardSession kind) => switch (kind) {
    ChatCardSession.terminalCli => AgentIds.claudeCode,
    ChatCardSession.acp => AgentIds.claudeAcp,
  };

  static AgentStatusReport idle(ChatCardSession kind) => statusOf(
    kind,
    AgentActivityStatus.idle,
  );

  static AgentStatusReport statusOf(
    ChatCardSession kind,
    AgentActivityStatus status, {
    AgentWaitKind waiting = AgentWaitKind.unrecorded,
    AgentToolAsk? toolAsk,
    List<String> evidence = const [],
  }) => AgentStatusReport(
    agentId: agentIdOf(kind),
    sessionId: 's1',
    status: status,
    observedAt: testTime,
    source: kind == ChatCardSession.acp
        ? AgentStatusSource.protocol
        : AgentStatusSource.hook,
    waiting: waiting,
    toolAsk: toolAsk,
    evidence: evidence,
    waitingSince: status == AgentActivityStatus.awaitingApproval
        ? testTime
        : null,
  );

  void record(List<TranscriptMessage> messages) => _messages.add(messages);

  void status(AgentStatusReport report) {
    _latest = report;
    _status.add(report);
  }

  Widget app({Size? size}) => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
    ),
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  Future<void> dispose() async {
    container.dispose();
    await _messages.close();
    await _status.close();
  }
}

/// A plan tool call as each face records it: Claude Code's `TodoWrite` row
/// in its transcript, or the server's `plan` row for an ACP plan update.
TranscriptMessage planRow(
  ChatCardSession kind,
  AgentPlan plan, {
  DateTime? at,
}) => switch (kind) {
  ChatCardSession.terminalCli => TranscriptMessage(
    role: 'tool',
    text: '',
    tool: ToolActivity(name: 'TodoWrite', subject: plan.headline, plan: plan),
    at: at ?? testTime,
  ),
  ChatCardSession.acp => TranscriptMessage(
    role: 'agent',
    text: '',
    tool: ToolActivity(name: 'plan', subject: plan.headline, plan: plan),
    at: at ?? testTime,
  ),
};

AgentPlan planOf(Map<String, AgentPlanItemState> items, {String note = ''}) =>
    AgentPlan(
      items: [
        for (final MapEntry(key: text, value: state) in items.entries)
          AgentPlanItem(text: text, state: state),
      ],
      note: note,
    );

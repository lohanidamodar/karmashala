import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/bot/application/bot_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

const botFeatures = {
  'bot',
  'sessions.send',
  'sessions.send.resumes',
  'sessions.interrupt',
  'sessions.queue',
  'sessions.switchAgent',
};

BotApproval approvalOf(String id, {String summary = 'Remove the worktree x'}) =>
    BotApproval(
      id: id,
      sessionId: 'bot-1',
      tool: 'worktree_remove',
      arguments: const {'path': 'x'},
      summary: summary,
      state: BotApprovalState.pending,
      requestedAt: DateTime.utc(2026, 11, 2),
      expiresAt: DateTime.utc(2026, 11, 2, 0, 10),
    );

/// A fake server with an ACP agent and a bot, and the app's container on it.
class BotRig {
  BotRig() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'a1',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    server.sessionWork
      ..typesSends = true
      ..running.add('bot-1');
  }

  late final TestMachine db;
  late final FakeDataServer server;

  FakeBot get bot => server.bot;

  /// The container, with [features] and any [overrides] over the defaults.
  Future<ProviderContainer> container({
    Set<String> features = botFeatures,
    List<Override> overrides = const [],
    List<TranscriptMessage> transcript = const [],
  }) async {
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        serverOfferProvider.overrideWithValue(
          ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: features,
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => true),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(transcript),
        ),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    container.listen(botFollowerProvider, (_, _) {});
    // Microtasks, not pumpEventQueue: that waits on a timer, which never fires
    // under testWidgets' fake clock.
    for (var i = 0; i < 20; i++) {
      await Future<void>.value();
    }
    return container;
  }
}

/// The row the bot's conversation is on, seeded before the client follows.
Session botRow(BotRig rig) => rig.bot.session = rig.bot.makeRow();

/// Sets the window and the text scale for one [tester] run.
void sizeWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The window sizes and text scales the panel is held to.
const panelMatrix = [
  ('360 phone', Size(360, 740), 1.0),
  ('360 phone at 1.6', Size(360, 740), 1.6),
  ('tablet', Size(700, 900), 1.0),
  ('tablet at 1.6', Size(700, 900), 1.6),
  ('wide desktop', Size(1600, 1000), 1.0),
  ('wide desktop at 1.6', Size(1600, 1000), 1.6),
];

/// Whether [container]'s client has been told [connected].
bool isConnected(ProviderContainer container) =>
    container.read(dataConnectionProvider).hasValue;

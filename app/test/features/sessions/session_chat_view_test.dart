import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_view_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session/launch.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// A locator that answers from a variable and counts how often it was asked, so
/// nothing here walks the owner's real store and "a closed panel costs nothing"
/// is a measurement rather than a hope.
class _CountingLocator implements SessionTranscriptLocator {
  _CountingLocator(this.path);

  String? path;
  int calls = 0;

  @override
  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async {
    calls++;
    return path;
  }

  @override
  Future<Map<String, String>> index() async =>
      path == null ? const {} : {'x': path!};
}

/// **Whether a session has a chat view is a reading, not an allowlist.**
///
/// The failure this file exists to stop: one sentence about a *store format*
/// standing in for every session of that agent. Antigravity's WSL install here
/// keeps a readable JSONL transcript for all 25 of its conversations and the
/// Windows one keeps none for its only one, so either setting of a per-format
/// flag lies about half the sessions on this machine — a confident false
/// statement, which §19 costs higher than an admission of ignorance.
void main() {
  final now = DateTime.utc(2026, 9, 9, 12);

  late Directory store;

  setUp(() {
    store = Directory.systemTemp.createTempSync('karmashala_chatview_');
  });

  tearDown(() {
    if (store.existsSync()) store.deleteSync(recursive: true);
  });

  /// `<store>/conversations/<id>.db` — the file identity is read from, and the
  /// only path a detected Antigravity session carries.
  String conversationRecord(String id) {
    final dir = Directory(p.join(store.path, 'conversations'))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, '$id.db'))
      ..writeAsStringSync('protobuf');
    return file.path;
  }

  /// The WSL shape: a plain JSONL transcript beside the record, which is what
  /// `antigravityTranscriptPathFor` reconstructs.
  void writeBrainTranscript(String id) {
    final dir = Directory(
      p.join(store.path, 'brain', id, '.system_generated', 'logs'),
    )..createSync(recursive: true);
    File(
      p.join(dir.path, 'transcript.jsonl'),
    ).writeAsStringSync('{"role":"user","content":"hi"}\n');
  }

  /// The Windows shape: the brain directory exists and is empty.
  void writeEmptyBrain(String id) {
    Directory(
      p.join(store.path, 'brain', id, '.system_generated', 'logs'),
    ).createSync(recursive: true);
  }

  Future<({ProviderContainer container, _CountingLocator locator})>
  containerFor({
    String agentId = AgentIds.claudeCode,
    String? externalSessionId = 'ext-1',
    String? located,
    AgentRegistry? registry,
  }) async {
    final db = AppDatabase.memory();
    final server = FakeDataServer()..mirrorInto(db);
    addTearDown(db.close);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation(agentId: agentId));
    server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Session',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        surface: SessionSurface.pane,
        externalSessionId: externalSessionId,
      ),
    );
    final locator = _CountingLocator(located);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(now)),
        sessionTranscriptLocatorProvider.overrideWithValue(locator),
        if (registry != null) agentRegistryProvider.overrideWithValue(registry),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, locator: locator);
  }

  Future<SessionChatView> readingFor({
    String agentId = AgentIds.claudeCode,
    String? externalSessionId = 'ext-1',
    String? located,
  }) async {
    final made = await containerFor(
      agentId: agentId,
      externalSessionId: externalSessionId,
      located: located,
    );
    final subscription = made.container.listen(
      sessionChatViewProvider('s1'),
      (_, _) {},
    );
    // Held open by the test: awaiting an `autoDispose` future nobody listens to
    // disposes it mid-flight.
    final probe = made.container.listen(
      sessionChatViewProbeProvider('s1'),
      (_, _) {},
    );
    await made.container.read(sessionChatViewProbeProvider('s1').future);
    final reading = subscription.read();
    probe.close();
    subscription.close();
    return reading;
  }

  group('Antigravity is read per session, because its two installs differ', () {
    test(
      'a Windows-shaped session has none, and says the file is absent',
      () async {
        const id = 'conv-win';
        final record = conversationRecord(id);
        writeEmptyBrain(id);
        final reading = await readingFor(
          agentId: AgentIds.antigravity,
          externalSessionId: id,
          located: record,
        );
        expect(reading.hasChatView, isFalse);
        expect(reading.evidence, ChatViewEvidence.transcriptAbsent);
        // The *why*, and it is not "this agent's store is unreadable": the store
        // is readable, and keeps nothing readable for this conversation.
        expect(reading.reason, contains('No transcript file for this session'));
        expect(reading.path, endsWith('transcript.jsonl'));
        // Final rather than a race, so the companion sends `noChatView` for it.
        expect(reading.keepsNoRecord, isTrue);
      },
    );

    test('a WSL-shaped session with a transcript has one', () async {
      const id = 'conv-wsl';
      final record = conversationRecord(id);
      writeBrainTranscript(id);
      final reading = await readingFor(
        agentId: AgentIds.antigravity,
        externalSessionId: id,
        located: record,
      );
      expect(reading.hasChatView, isTrue);
      expect(reading.evidence, ChatViewEvidence.transcriptOnDisk);
      expect(reading.keepsNoRecord, isFalse);
      // The allowlist still refuses the agent; the reading overrules it, which
      // is the whole point of measuring one session at a time.
      expect(reading.prior, isFalse);
    });

    test('every reading that looked at a disk carries its age', () async {
      const id = 'conv-wsl';
      final record = conversationRecord(id);
      writeBrainTranscript(id);
      final reading = await readingFor(
        agentId: AgentIds.antigravity,
        externalSessionId: id,
        located: record,
      );
      expect(reading.checkedAt, now);
      expect(
        reading.ageAt(now.add(const Duration(minutes: 3))),
        const Duration(minutes: 3),
      );
      expect(reading.isMeasured, isTrue);
    });

    test('a session the store scan could not find is neither answer', () async {
      // Not a refusal: an Antigravity conversation we never located is a gap,
      // and a gap must not be dressed up as "this agent keeps no record".
      final reading = await readingFor(
        agentId: AgentIds.antigravity,
        externalSessionId: 'conv-missing',
      );
      expect(reading.evidence, ChatViewEvidence.notLocated);
      expect(reading.hasChatView, isFalse, reason: 'the prior refuses');
      expect(reading.keepsNoRecord, isFalse);
    });
  });

  group('the allowlist is the prior, and for two agents it is the answer', () {
    test('Claude Code has a chat view and costs no scan', () async {
      final made = await containerFor();
      final reading = made.container.read(sessionChatViewProvider('s1'));
      expect(reading.hasChatView, isTrue);
      expect(reading.evidence, ChatViewEvidence.unread);
      expect(reading.prior, isTrue);
      expect(reading.checkedAt, isNull, reason: 'nothing was looked at');
      expect(made.locator.calls, 0);
    });

    test('Codex is unchanged too', () async {
      final made = await containerFor(agentId: AgentIds.codex);
      expect(
        made.container.read(sessionChatViewProvider('s1')).hasChatView,
        isTrue,
      );
      expect(made.locator.calls, 0);
    });

    test('the prior is what an unread session answers from', () async {
      // Said out loud, because "not looked at yet" and "there is no chat view"
      // are different sentences and the reading must not collapse them.
      const unread = SessionChatView.unread(prior: false);
      expect(unread.isMeasured, isFalse);
      expect(unread.hasChatView, isFalse);
      expect(unread.reason, contains('Not looked at yet'));
      expect(unread.keepsNoRecord, isFalse);
    });
  });

  group('what the screen answers for free', () {
    test('a session with no CLI id yet has nothing to look for', () async {
      final made = await containerFor(externalSessionId: null);
      final reading = made.container.read(sessionChatViewProvider('s1'));
      expect(reading.evidence, ChatViewEvidence.noSessionRecord);
      expect(reading.hasChatView, isFalse);
      // A gap, not a refusal: it closes on its own once the CLI names the
      // conversation, so the phone must not be told "no chat view for this".
      expect(reading.keepsNoRecord, isFalse);
      expect(made.locator.calls, 0);
    });

    test(
      'an agent whose store nothing here opens says so, and is final',
      () async {
        // An agent that exists only as registry data — the "this agent's store is
        // unreadable" sentence, answered from the registry for every session of
        // it at once and never from a disk.
        const rover = AgentDescriptor(
          id: 'roverCli',
          displayName: 'Rover',
          binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
          store: AgentStoreSpec(homeDirectoryName: '.rover'),
        );
        final made = await containerFor(
          agentId: rover.id,
          registry: const AgentRegistry([DataOnlyAgentAdapter(rover)]),
        );
        final reading = made.container.read(sessionChatViewProvider('s1'));
        expect(reading.evidence, ChatViewEvidence.storeUnreadable);
        expect(reading.hasChatView, isFalse);
        expect(reading.keepsNoRecord, isTrue);
        expect(reading.reason, contains('store is unreadable'));
        expect(made.locator.calls, 0);
      },
    );
  });

  group('a closed panel subscribes to nothing', () {
    test('nobody listening means no scan at all', () async {
      const id = 'conv-wsl';
      final record = conversationRecord(id);
      writeBrainTranscript(id);
      final made = await containerFor(
        agentId: AgentIds.antigravity,
        externalSessionId: id,
        located: record,
      );
      // A frame's worth of other work, with every surface that would ask shut.
      made.container.read(sessionsDataProvider).getById('s1');
      await Future<void>.delayed(Duration.zero);
      expect(made.locator.calls, 0);
    });

    test(
      'one open surface costs one scan, and closing it stops there',
      () async {
        const id = 'conv-wsl';
        final record = conversationRecord(id);
        writeBrainTranscript(id);
        final made = await containerFor(
          agentId: AgentIds.antigravity,
          externalSessionId: id,
          located: record,
        );
        final subscription = made.container.listen(
          sessionChatViewProbeProvider('s1'),
          (_, _) {},
        );
        await made.container.read(sessionChatViewProbeProvider('s1').future);
        expect(made.locator.calls, 1);
        subscription.close();
        // Nothing re-arms: the probe runs when a surface asks and never again.
        await Future<void>.delayed(Duration.zero);
        expect(made.locator.calls, 1);
      },
    );
  });
}

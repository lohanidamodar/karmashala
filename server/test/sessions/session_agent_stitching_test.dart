import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:agent_cli/read.dart' show TranscriptMessage, kAgentSwitchRole;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionTranscriptRead;
import 'package:karmashala_host/src/sessions/session_agent_stitching.dart';
import 'package:karmashala_host/src/sessions/session_message_transcripts.dart';
import 'package:karmashala_host/src/sessions/session_transcripts.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart' show ChatViewEvidence;
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// A switched session's transcript: each span from its own source, in switch
/// order, every row tagged with its agent and each switch drawn as one
/// `agentSwitch` row carrying the packet â€” never the packet as a user turn.
void main() {
  final t0 = DateTime.utc(2026, 10, 3, 9);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));
  TranscriptMessage row(String role, String text, int minute) =>
      TranscriptMessage(role: role, text: text, at: at(minute));

  group('stitchAgentSpans', () {
    test('spans follow each other, tagged, the packet folded into the '
        'divider', () {
      final claudeFile = [
        row('user', 'make it fast', 0),
        row('agent', 'Cached it.', 1),
        // Its own conversation resumed later, after the ACP span.
        row('user', 'Here is what you missed: tests added.', 20),
        row('agent', 'Reviewed the tests.', 21),
      ];
      final acpRows = [
        row('user', '# Handed off from Claude Code\n\nall of it', 10),
        row('agent', 'Tests added.', 11),
      ];
      final stitched = stitchAgentSpans([
        (
          span: SessionAgentSpan(
            sessionId: 's',
            seq: 0,
            agentInstallationId: 'claude',
            startedAt: t0,
            externalSessionId: 'conv-1',
          ),
          fromMessages: false,
          rows: claudeFile,
        ),
        (
          span: SessionAgentSpan(
            sessionId: 's',
            seq: 1,
            agentInstallationId: 'acp',
            startedAt: at(5),
            firstMessageOrdinal: 0,
            carriedPacket: '# Handed off from Claude Code\n\nall of it',
          ),
          fromMessages: true,
          rows: acpRows,
        ),
        (
          span: SessionAgentSpan(
            sessionId: 's',
            seq: 2,
            agentInstallationId: 'claude',
            startedAt: at(15),
            externalSessionId: 'conv-1',
            carriedPacket: 'Here is what you missed: tests added.',
          ),
          fromMessages: false,
          rows: claudeFile,
        ),
      ]);
      expect(
        stitched.map((m) => (m.role, m.text, m.agentInstallationId)),
        [
          ('user', 'make it fast', 'claude'),
          ('agent', 'Cached it.', 'claude'),
          (
            kAgentSwitchRole,
            '# Handed off from Claude Code\n\nall of it',
            'acp',
          ),
          ('agent', 'Tests added.', 'acp'),
          (kAgentSwitchRole, 'Here is what you missed: tests added.', 'claude'),
          ('agent', 'Reviewed the tests.', 'claude'),
        ],
      );
    });

    test('ACP spans are cut by ordinal, and a typed instruction that is not '
        'the packet stays', () {
      final rows = [
        row('user', 'one', 0),
        row('agent', 'two', 1),
        row('user', 'do the next thing', 5),
        row('agent', 'three', 6),
      ];
      final stitched = stitchAgentSpans([
        (
          span: SessionAgentSpan(
            sessionId: 's',
            seq: 0,
            agentInstallationId: 'a',
            startedAt: t0,
            firstMessageOrdinal: 0,
          ),
          fromMessages: true,
          rows: rows,
        ),
        (
          span: SessionAgentSpan(
            sessionId: 's',
            seq: 1,
            agentInstallationId: 'b',
            startedAt: at(4),
            firstMessageOrdinal: 2,
            carriedPacket: 'packet',
          ),
          fromMessages: true,
          rows: rows,
        ),
      ]);
      expect(stitched.map((m) => (m.text, m.agentInstallationId)), [
        ('one', 'a'),
        ('two', 'a'),
        ('packet', 'b'),
        ('do the next thing', 'b'),
        ('three', 'b'),
      ]);
    });
  });

  group('SessionTranscripts', () {
    late AppDatabase db;
    late Directory temp;
    late SessionMessageDao messages;
    late List<SessionAgentSpan> spans;

    setUp(() {
      db = AppDatabase.memory();
      db.execute('PRAGMA foreign_keys = OFF;');
      temp = Directory.systemTemp.createTempSync('stitch_test');
      messages = SessionMessageDao(db, now: () => t0);
      spans = [];
    });
    tearDown(() {
      db.close();
      temp.deleteSync(recursive: true);
    });

    SessionTranscripts transcripts(String claudeFile) => SessionTranscripts(
      lookUp: (_) async => (
        path: null,
        agentId: null,
        absence: ChatViewEvidence.noSessionRecord,
      ),
      messages: SessionMessageTranscriptSource(messages),
      servesFromMessages: (_) => true,
      spans: AgentSpanReaders(
        spansOf: (_) => spans,
        agentIdOf: (id) => id == 'cc' ? AgentIds.claudeCode : AgentIds.claudeAcp,
        speaksAcp: (id) => id == 'acp',
        locate: (agentId, conversation) async =>
            agentId == AgentIds.claudeCode && conversation == 'conv-c'
            ? claudeFile
            : null,
      ),
    );

    void say(String id, SessionMessageRole role, String text) =>
        messages.append(
          SessionMessage(
            id: id,
            sessionId: 's',
            role: role,
            text: text,
            createdAt: t0,
            updatedAt: t0,
          ),
        );

    String claudeRecord(List<(String, String, DateTime)> lines) {
      final file = File('${temp.path}${Platform.pathSeparator}c.jsonl');
      file.writeAsStringSync([
        for (final (role, text, stamp) in lines)
          jsonEncode(
            role == 'user'
                ? {
                    'type': 'user',
                    'timestamp': stamp.toIso8601String(),
                    'message': {'role': 'user', 'content': text},
                  }
                : {
                    'type': 'assistant',
                    'timestamp': stamp.toIso8601String(),
                    'message': {
                      'content': [
                        {'type': 'text', 'text': text},
                      ],
                    },
                  },
          ),
      ].join('\n'));
      return file.path;
    }

    test('a session that never switched is read as before', () async {
      say('u', SessionMessageRole.user, 'hi');
      final rows = await transcripts('').messagesOf('s');
      expect(rows.map((m) => (m.text, m.agentInstallationId)), [('hi', null)]);
    });

    test('ACP turns then a terminal agent\'s file, stitched in order', () async {
      say('u', SessionMessageRole.user, 'tidy the routes');
      say('a', SessionMessageRole.agent, 'Routes tidied.');
      final file = claudeRecord([
        ('user', 'continue please', at(10)),
        ('agent', 'Docs written.', at(11)),
      ]);
      spans = [
        SessionAgentSpan(
          sessionId: 's',
          seq: 0,
          agentInstallationId: 'acp',
          startedAt: t0,
          firstMessageOrdinal: 0,
        ),
        SessionAgentSpan(
          sessionId: 's',
          seq: 1,
          agentInstallationId: 'cc',
          startedAt: at(5),
          externalSessionId: 'conv-c',
          carriedPacket: 'the packet',
        ),
      ];
      final source = transcripts(file);
      final rows = await source.messagesOf('s');
      expect(rows.map((m) => (m.role, m.text, m.agentInstallationId)), [
        ('user', 'tidy the routes', 'acp'),
        ('agent', 'Routes tidied.', 'acp'),
        (kAgentSwitchRole, 'the packet', 'cc'),
        ('user', 'continue please', 'cc'),
        ('agent', 'Docs written.', 'cc'),
      ]);
      final page = await source.page(const SessionTranscriptRead('s'));
      expect(page.total, 5);
      expect(page.messages.last.agentInstallationId, 'cc');
    });
  });
}

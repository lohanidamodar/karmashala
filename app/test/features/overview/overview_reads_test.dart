import 'dart:async';

import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/overview/application/overview_reads.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/data/server_transcripts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/transcript.dart' show ChatViewEvidence;

/// A server's transcript reads, answered from the test.
class _Transcripts implements ServerTranscripts {
  Future<ServerTurns> Function(String id)? onTurns;
  Future<TranscriptPage> Function(String id, int limit)? onGlance;
  final turnsAsked = <String>[];
  final glanced = <(String, int)>[];

  @override
  Future<ServerTurns> turns(
    String sessionId, {
    bool spoken = false,
    required bool Function(List<TranscriptMessage> held) enough,
    void Function(int held, int total)? progress,
  }) {
    turnsAsked.add(sessionId);
    return onTurns!(sessionId);
  }

  @override
  Future<TranscriptPage> glance(String sessionId, {int limit = 1}) {
    glanced.add((sessionId, limit));
    return onGlance!(sessionId, limit);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TranscriptMessage _say(String role, String text) =>
    TranscriptMessage(role: role, text: text);

TranscriptPage _page(List<TranscriptMessage> rows, {ChatViewEvidence? absence}) =>
    TranscriptPage(
      sessionId: 's1',
      generation: absence == null ? 'g' : '',
      revision: 1,
      total: rows.length,
      from: 0,
      messages: rows,
      absence: absence,
    );

/// **The peek's last answer**, read once rather than through the chat's feed,
/// which reads only while a chat is on screen — the cause of a "Reading…"
/// that never ended on the Overview.
void main() {
  late _Transcripts transcripts;

  ProviderContainer container(Set<String> features) {
    final c = ProviderContainer(
      overrides: [
        serverOfferProvider.overrideWithValue(
          ServerOffer(sameMachine: true, features: features),
        ),
        serverTranscriptsProvider.overrideWithValue(transcripts),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  const both = {'sessions.transcript', 'sessions.transcript.turns'};

  setUp(() => transcripts = _Transcripts());

  test('loads with no chat on screen, from the server\'s turns', () async {
    transcripts.onTurns = (_) async => ServerTurns([
      _say('user', 'Fix the peek'),
      _say('agent', 'Fixed. **The peek** reads its answer once now.'),
      _say('user', 'Thanks'),
    ], total: 3);
    final c = container(both);
    expect(c.read(chatTranscriptPollingProvider), isFalse);
    final answer = await c.read(overviewReaderProvider).lastAnswer('s1');
    expect(answer.text, 'Fixed. **The peek** reads its answer once now.');
    expect(transcripts.turnsAsked, ['s1']);
  });

  test('says there is none yet, rather than reading for ever', () async {
    transcripts.onTurns = (_) async =>
        ServerTurns([_say('user', 'Start')], total: 1);
    final answer = await container(
      both,
    ).read(overviewReaderProvider).lastAnswer('s1');
    expect(answer.text, isNull);
    expect(answer.why, 'No answer recorded yet.');
  });

  test('says why when the server has no record to read', () async {
    transcripts.onTurns = (_) async => const ServerTurns(
      [],
      total: 0,
      absence: ChatViewEvidence.notLocated,
    );
    final answer = await container(
      both,
    ).read(overviewReaderProvider).lastAnswer('s1');
    expect(answer.why, startsWith('There is no conversation record to read'));
  });

  test('says the server\'s words when it refuses', () async {
    transcripts.onTurns = (_) async =>
        throw const DataRefused.denied('this link may not read transcripts');
    final answer = await container(
      both,
    ).read(overviewReaderProvider).lastAnswer('s1');
    expect(
      answer.why,
      'The server could not read this conversation: '
      'this link may not read transcripts',
    );
  });

  testWidgets('says so when the server never answers', (tester) async {
    transcripts.onTurns = (_) => Completer<ServerTurns>().future;
    final c = container(both);
    LastAnswer? answer;
    unawaited(
      c.read(overviewReaderProvider).lastAnswer('s1').then((a) => answer = a),
    );
    await tester.pump(kOverviewReadTimeout + const Duration(seconds: 1));
    expect(answer?.why, contains('did not answer within 15 s'));
  });

  test('an older server without turns is read through its pages', () async {
    transcripts.onGlance = (_, _) async =>
        _page([_say('agent', 'Done: the tag is pushed.')]);
    final answer = await container({
      'sessions.transcript',
    }).read(overviewReaderProvider).lastAnswer('s1');
    expect(answer.text, 'Done: the tag is pushed.');
    expect(transcripts.glanced, [('s1', 40)]);
    expect(transcripts.turnsAsked, isEmpty);
  });

  test('a turns read refused as unknown falls back to the pages', () async {
    transcripts.onTurns = (_) async =>
        throw const DataRefused.invalid('unknown kind');
    transcripts.onGlance = (_, _) async =>
        _page([_say('agent', 'From a page.')]);
    final answer = await container(
      both,
    ).read(overviewReaderProvider).lastAnswer('s1');
    expect(answer.text, 'From a page.');
  });

  test('the provider answers through the reader', () async {
    transcripts.onTurns = (_) async =>
        ServerTurns([_say('agent', 'Hello')], total: 1);
    final c = container(both);
    expect(await c.read(overviewLastAnswerProvider('s1').future), const LastAnswer.of('Hello'));
  });
}

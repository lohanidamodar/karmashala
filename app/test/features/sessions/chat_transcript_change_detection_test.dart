import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What tells the conversation its file moved.**
///
/// `sessionChatTranscriptProvider` re-reads a transcript only when the poll
/// says the file changed, because a read is a whole-file JSONL parse — 650-870
/// ms for this machine's live session. Whatever that decision is keyed on is
/// therefore the difference between a live conversation and one frozen at the
/// message before last.
///
/// The key was `stat.modified` alone, and Dart's mtime is not distinct per
/// write: two writes inside one tick report the same timestamp, so a poll whose
/// `stat` lands between them never learns about the second. A transcript is
/// append-only, so its size moves even when the clock does not — which is why
/// the key is `(modified, size)` and what these cases pin. `docs/SETTLED.md`,
/// *Four transcript-tailing traps*, has the measurement.
void main() {
  late Directory dir;
  late File transcript;
  late AppDatabase db;
  late FakeDataServer server;
  late DataClient data;

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    data = await server.connect();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    mirroredServer(db).sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Session s1',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        externalSessionId: 'ext-s1',
      ),
    );
    dir = Directory.systemTemp.createTempSync('karmashala-chat-change');
    transcript = File(p.join(dir.path, 'session.jsonl'))
      ..writeAsStringSync(_claudeLine('first'));
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can still hold the handle; the temp directory is disposable.
    }
  });

  ProviderContainer pollingContainer() {
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        chatTranscriptPollIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 5),
        ),
        sessionTranscriptLocatorProvider.overrideWith(
          (ref) => _FixedLocator(ref, transcript.path),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(terminalFacesProvider.notifier).show('g', terminal: false);
    return container;
  }

  /// Waits until [check] holds, or gives up. Condition-based rather than a
  /// fixed sleep: the poll runs on a real timer.
  Future<bool> waitFor(bool Function() check) async {
    for (var i = 0; i < 400; i++) {
      if (check()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return check();
  }

  /// Subscribes and returns the list every read has produced so far.
  List<List<TranscriptMessage>> watch(ProviderContainer container) {
    final seen = <List<TranscriptMessage>>[];
    final sub = container.listen(sessionChatTranscriptProvider('s1'), (
      _,
      next,
    ) {
      final value = next.asData?.value;
      if (value != null && value.isNotEmpty) seen.add(value);
    }, fireImmediately: true);
    addTearDown(sub.close);
    return seen;
  }

  /// Pauses the poll, applies [change], and lets it run again.
  ///
  /// The pause is what makes the case deterministic rather than a race: the
  /// loop keeps `lastModified` across one, so the first tick back is the tick
  /// under test, and no read can slip between the write and the timestamp
  /// being pinned.
  Future<void> whilePaused(
    ProviderContainer container,
    void Function() change,
  ) async {
    final faces = container.read(terminalFacesProvider.notifier);
    faces.show('g', terminal: true);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    change();
    faces.show('g', terminal: false);
  }

  test(
    'a record appended inside the same timestamp tick is still read',
    () async {
      final container = pollingContainer();
      final seen = watch(container);
      expect(
        await waitFor(() => seen.isNotEmpty),
        isTrue,
        reason: 'the guard against a false green: the poll has to work at all',
      );

      final before = seen.length;
      await whilePaused(container, () {
        // Exactly what the filesystem does to us when two writes share a tick:
        // the file grew, and the clock did not move.
        final tick = transcript.statSync().modified;
        transcript.writeAsStringSync(
          '${_claudeLine('first')}${_claudeLine('second')}',
        );
        transcript.setLastModifiedSync(tick);
      });

      expect(
        await waitFor(() => seen.length > before && seen.last.length == 2),
        isTrue,
        reason:
            'the conversation froze on the message before last: the append was '
            'invisible because only the mtime was compared, and the mtime did '
            'not move',
      );
      expect(seen.last.map((m) => m.text), ['first', 'second']);
    },
  );

  test(
    'a rewrite inside the same tick that shrinks the file is still read',
    () async {
      final container = pollingContainer();
      transcript.writeAsStringSync(
        '${_claudeLine('first')}${_claudeLine('second')}',
      );
      final seen = watch(container);
      expect(await waitFor(() => seen.isNotEmpty), isTrue);

      final before = seen.length;
      await whilePaused(container, () {
        final tick = transcript.statSync().modified;
        transcript.writeAsStringSync(_claudeLine('first'));
        transcript.setLastModifiedSync(tick);
      });

      expect(
        await waitFor(() => seen.length > before && seen.last.length == 1),
        isTrue,
        reason: 'a truncation inside one tick is a change like any other',
      );
    },
  );

  test('a file that did not change is not re-read', () async {
    // The other half of the bargain: size joined the key to catch a change,
    // not to manufacture one. A 650-870 ms parse per tick is the cost of
    // getting this wrong.
    final container = pollingContainer();
    final seen = watch(container);
    expect(await waitFor(() => seen.isNotEmpty), isTrue);

    final after = seen.length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      seen.length,
      after,
      reason:
          'roughly 40 ticks at this container\'s 5 ms interval, over a file '
          'nothing touched: not one of them may re-read it',
    );
  });
}

/// One Claude Code transcript line, in the shape `readCliTranscript` parses.
String _claudeLine(String text) =>
    '${jsonEncode({
      'type': 'user',
      'timestamp': testTime.toIso8601String(),
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    })}\n';

/// A locator that already knows where the file is, so what is under test is
/// the read loop rather than the store scan in front of it.
class _FixedLocator extends SessionTranscriptLocator {
  _FixedLocator(super.ref, this.path);

  final String path;

  @override
  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async => path;

  @override
  Future<Map<String, String>> index() async => {'x': path};
}

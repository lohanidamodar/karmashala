@Tags(['cost'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/cli_detection/application/conversation_indexer.dart';
import 'package:karmashala/src/features/cli_detection/application/session_search.dart';
import 'package:karmashala/src/features/cli_detection/data/conversation_index_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// Times the DAO's writes: `package:sqlite3` is synchronous, so this is the
/// share of indexing that lands on the isolate that draws.
class _TimedDao extends ConversationIndexDao {
  _TimedDao(super.db);

  final Stopwatch writing = Stopwatch();

  @override
  void replaceTurns({
    required String sessionId,
    required String cli,
    required String filePath,
    required List<ConversationTurn> turns,
    required DateTime indexedAt,
    DateTime? modifiedAt,
    int? size,
    TranscriptResumePoint? resumePoint,
  }) {
    writing.start();
    super.replaceTurns(
      sessionId: sessionId,
      cli: cli,
      filePath: filePath,
      turns: turns,
      indexedAt: indexedAt,
      modifiedAt: modifiedAt,
      size: size,
      resumePoint: resumePoint,
    );
    writing.stop();
  }

  @override
  void appendTurns({
    required String sessionId,
    required String cli,
    required String filePath,
    required List<ConversationTurn> turns,
    required int fromOrdinal,
    required int heldTurns,
    required DateTime indexedAt,
    required TranscriptResumePoint resumePoint,
    DateTime? modifiedAt,
    int? size,
  }) {
    writing.start();
    super.appendTurns(
      sessionId: sessionId,
      cli: cli,
      filePath: filePath,
      turns: turns,
      fromOrdinal: fromOrdinal,
      heldTurns: heldTurns,
      indexedAt: indexedAt,
      resumePoint: resumePoint,
      modifiedAt: modifiedAt,
      size: size,
    );
    writing.stop();
  }
}

/// A synthetic store: a Zipf-distributed vocabulary, Claude Code's JSONL
/// shape, and most of the bytes in tool output — as real transcripts have.
class _Corpus {
  _Corpus(this.random) {
    const letters = 'abcdefghijklmnopqrstuvwxyz';
    final words = <String>{};
    while (words.length < 20000) {
      final length = 3 + random.nextInt(8);
      words.add(
        String.fromCharCodes([
          for (var i = 0; i < length; i++)
            letters.codeUnitAt(random.nextInt(letters.length)),
        ]),
      );
    }
    vocabulary = words.toList();
    var total = 0.0;
    for (var rank = 1; rank <= vocabulary.length; rank++) {
      total += 1 / rank;
      _cumulative.add(total);
    }
  }

  final Random random;
  late final List<String> vocabulary;
  final List<double> _cumulative = [];

  String word() {
    final target = random.nextDouble() * _cumulative.last;
    var lo = 0;
    var hi = _cumulative.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_cumulative[mid] < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return vocabulary[lo];
  }

  String sentence(int words) =>
      [for (var i = 0; i < words; i++) word()].join(' ');

  var _call = 0;

  /// One exchange: a prompt, a reply, and a few tool calls with output.
  String exchange() {
    final out = StringBuffer()
      ..write(
        '${jsonEncode({
          'type': 'user',
          'timestamp': '2026-09-21T10:00:00.000Z',
          'message': {'role': 'user', 'content': sentence(10 + random.nextInt(30))},
        })}\n',
      );
    for (var c = random.nextInt(4); c > 0; c--) {
      final id = 'toolu_${_call++}';
      out
        ..write(
          '${jsonEncode({
            'type': 'assistant',
            'message': {
              'content': [
                {
                  'type': 'tool_use',
                  'id': id,
                  'name': 'Bash',
                  'input': {'command': 'grep -rn ${word()} lib'},
                },
              ],
            },
          })}\n',
        )
        ..write(
          '${jsonEncode({
            'type': 'user',
            'message': {
              'content': [
                {'type': 'tool_result', 'tool_use_id': id, 'content': sentence(40 + random.nextInt(600))},
              ],
            },
          })}\n',
        );
    }
    out.write(
      '${jsonEncode({
        'type': 'assistant',
        'timestamp': '2026-09-21T10:00:05.000Z',
        'message': {
          'content': [
            {'type': 'text', 'text': sentence(20 + random.nextInt(100))},
          ],
        },
      })}\n',
    );
    return out.toString();
  }
}

double _ms(Stopwatch w) => w.elapsedMicroseconds / 1000;

String _percentiles(List<double> samples) {
  final sorted = [...samples]..sort();
  double at(double p) =>
      sorted[((sorted.length - 1) * p).round().clamp(0, sorted.length - 1)];
  return 'p50 ${at(.5).toStringAsFixed(2)} ms  '
      'p95 ${at(.95).toStringAsFixed(2)} ms  '
      'max ${sorted.last.toStringAsFixed(2)} ms  (n=${sorted.length})';
}

/// **Session search, priced** — index build, the warm sweep, an append, and
/// query latency, at Orca's measured scale (5,000 transcripts, ~87 MB) and at
/// the size of this machine's largest live transcript (~70 MB).
///
/// Opt-in: `KARMASHALA_SEARCH_BENCH=1`. Synthetic data only, in a temp
/// directory, printed as numbers. It asserts only that the searches found
/// something — a number is a reading of the machine, not a gate.
void main() {
  final enabled = Platform.environment['KARMASHALA_SEARCH_BENCH'] == '1';

  test(
    'session search at scale',
    () async {
      final dir = Directory.systemTemp.createTempSync('session_search_bench_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // A handle Windows has not let go of yet; the temp dir is swept.
        }
      });
      final corpus = _Corpus(Random(20029));
      final store = Directory('${dir.path}/store')..createSync();

      // --- 5,000 transcripts ----------------------------------------------
      const count = 5000;
      var bytes = 0;
      final paths = <String>[];
      for (var i = 0; i < count; i++) {
        final path = '${store.path}/c$i.jsonl';
        final content = StringBuffer();
        for (var e = 2 + corpus.random.nextInt(6); e > 0; e--) {
          content.write(corpus.exchange());
        }
        File(path).writeAsStringSync(content.toString());
        bytes += File(path).lengthSync();
        paths.add(path);
      }

      final dbDir = Directory('${dir.path}/db')..createSync();
      final db = AppDatabase.open(dbDir);
      addTearDown(db.close);
      final server = FakeDataServer()..mirrorInto(db);
      server.environmentRows.upsert(windowsEnv());
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      server.installationRows.insert(agentInstallation());
      final sessions = mirroredServer(db).sessionRows;
      db.transaction(() {
        for (var i = 0; i < count; i++) {
          sessions.insert(
            Session(
              id: 's$i',
              repositoryId: 'r1',
              agentInstallationId: 'a1',
              title: 'Session $i',
              useWorktree: false,
              status: SessionStatus.completed,
              createdAt: testTime,
              externalSessionId: 'c$i',
            ),
          );
        }
      });
      final dao = _TimedDao(db);
      final clock = MovableClock(DateTime.utc(2026, 9, 21, 12));
      final indexer = ConversationIndexer(dao: dao, clock: clock);

      Future<void> sweep() async {
        for (var i = 0; i < count; i++) {
          await indexer.indexConversation(
            conversationId: 'c$i',
            cli: AgentIds.claudeCode,
            filePath: paths[i],
          );
        }
      }

      final cold = Stopwatch()..start();
      await sweep();
      cold.stop();
      final coldWrites = _ms(dao.writing);
      final turns = db
          .query('SELECT COUNT(*) AS n FROM conversation_turns;')
          .single['n'];
      final pageSize =
          db.query('PRAGMA page_size;').single.values.first! as int;
      final pages = db.query('PRAGMA page_count;').single.values.first! as int;

      dao.writing.reset();
      final warm = Stopwatch()..start();
      await sweep();
      warm.stop();

      // Append one exchange to 100 of them, as a working hour would.
      final appended = <int>[for (var i = 0; i < 100; i++) i * 50];
      var appendBytes = 0;
      for (final i in appended) {
        final extra = corpus.exchange();
        appendBytes += utf8.encode(extra).length;
        File(paths[i]).writeAsStringSync(extra, mode: FileMode.append);
      }
      dao.writing.reset();
      final bytesBefore = indexer.bytesRead;
      final append = Stopwatch()..start();
      for (final i in appended) {
        await indexer.indexConversation(
          conversationId: 'c$i',
          cli: AgentIds.claudeCode,
          filePath: paths[i],
        );
      }
      append.stop();
      final appendRead = indexer.bytesRead - bytesBefore;
      final appendWrites = _ms(dao.writing);

      // --- query latency ----------------------------------------------------
      final search = SessionSearchService(dao: dao, clock: clock);
      final common = [for (var r = 0; r < 20; r++) corpus.vocabulary[r]];
      final rare = [for (var r = 5000; r < 5040; r += 2) corpus.vocabulary[r]];
      String typo(String w) => w.length < 5
          ? '${w}q'
          : '${w.substring(0, 2)}${w[3]}${w[2]}${w.substring(4)}';
      final queries = <String, List<String>>{
        'one common word': common,
        'one rare word': rare,
        'two words': [for (var r = 0; r < 20; r++) '${common[r]} ${rare[r]}'],
        'typing a prefix': [for (final w in rare) w.substring(0, 3)],
        'a misspelt word (len>=6)': [
          for (var r = 3000; r < 3400; r++)
            if (corpus.vocabulary[r].length >= 6) typo(corpus.vocabulary[r]),
        ].take(20).toList(),
        'nothing matches': [for (var r = 0; r < 20; r++) 'zzqx$r yyqv$r'],
      };
      final lines = <String>[];
      final all = <double>[];
      var found = 0;
      for (final entry in queries.entries) {
        final samples = <double>[];
        for (final q in entry.value) {
          // Warm the statement cache once, then measure.
          search.search(q);
          final w = Stopwatch()..start();
          final page = search.search(q);
          w.stop();
          if (page.hits.isNotEmpty) found++;
          samples.add(_ms(w));
        }
        all.addAll(samples);
        lines.add('  ${entry.key.padRight(26)} ${_percentiles(samples)}');
      }

      // Where one common word's time goes: the ranking, the excerpts, and
      // the bare full-text scan under them.
      double timeIt(void Function() body) {
        body();
        final w = Stopwatch()..start();
        for (var i = 0; i < 5; i++) {
          body();
        }
        return w.elapsedMicroseconds / 5000;
      }

      final hot = common.first;
      final rankMs = timeIt(() => dao.rankConversations('"$hot"*', limit: 21));
      final exactMs = timeIt(() => dao.rankConversations('"$hot"', limit: 21));
      final ranked = dao.rankConversations('"$hot"*', limit: 21);
      final excerptMs = timeIt(
        () => dao.turnsById([for (final r in ranked) r.bestTurnId]),
      );
      final scanMs = timeIt(
        () => db.query(
          'SELECT rowid, bm25(conversation_turns_fts) FROM '
          'conversation_turns_fts WHERE conversation_turns_fts MATCH ? '
          'ORDER BY rowid DESC LIMIT 4000;',
          ['"$hot"*'],
        ),
      );
      final docs = dao.documentsWith(hot);
      lines.add(
        '  breakdown, "$hot" in $docs turns: rank ${rankMs.toStringAsFixed(2)} ms '
        '(as an exact word ${exactMs.toStringAsFixed(2)} ms), excerpts '
        '${excerptMs.toStringAsFixed(2)} ms, bare scan+bm25 of 4000 '
        '${scanMs.toStringAsFixed(2)} ms',
      );

      // --- one 70 MB transcript --------------------------------------------
      final bigPath = '${store.path}/big.jsonl';
      final sink = File(bigPath).openWrite();
      var bigBytes = 0;
      while (bigBytes < 70 * 1024 * 1024) {
        final e = corpus.exchange();
        sink.write(e);
        bigBytes += e.length;
      }
      await sink.close();
      final bigSize = File(bigPath).lengthSync();
      sessions.insert(
        Session(
          id: 'sbig',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Big',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
          externalSessionId: 'big',
        ),
      );
      final firstOpen = Stopwatch()..start();
      (await File(bigPath).open()).closeSync();
      firstOpen.stop();
      dao.writing.reset();
      final bigCold = Stopwatch()..start();
      await indexer.indexConversation(
        conversationId: 'big',
        cli: AgentIds.claudeCode,
        filePath: bigPath,
      );
      bigCold.stop();
      final bigColdWrites = _ms(dao.writing);
      final bigTurns = dao.turnCountFor('big');

      // Each round: append, then time opening the file on its own — which
      // is what an on-access scanner charges for a modified file — and then
      // the index of the append, whose own read opens it again.
      final tick = corpus.exchange();
      final opens = <double>[];
      final ticks = <double>[];
      final tickWrites = <double>[];
      var bigAppendBytes = 0;
      for (var round = 0; round < 5; round++) {
        File(bigPath).writeAsStringSync(tick, mode: FileMode.append);
        final open = Stopwatch()..start();
        (await File(bigPath).open()).closeSync();
        open.stop();
        opens.add(_ms(open));
        dao.writing.reset();
        final bigBefore = indexer.bytesRead;
        final one = Stopwatch()..start();
        await indexer.indexConversation(
          conversationId: 'big',
          cli: AgentIds.claudeCode,
          filePath: bigPath,
        );
        one.stop();
        ticks.add(_ms(one));
        tickWrites.add(_ms(dao.writing));
        bigAppendBytes = indexer.bytesRead - bigBefore;
      }

      // What the append replaced: parsing the whole file again.
      final reread = Stopwatch()..start();
      await readTranscriptTurns(
        bigPath,
        AgentIds.claudeCode,
        roles: kIndexedTranscriptRoles,
      );
      reread.stop();

      // --- v56 on an existing v55 index ------------------------------------
      final raw = sqlite3.open('${dir.path}/v55.sqlite');
      for (final v
          in schemaMigrations.keys.where((v) => v <= 55).toList()..sort()) {
        schemaMigrations[v]!(raw);
      }
      raw.execute('BEGIN;');
      final insert = raw.prepare(
        'INSERT INTO conversation_turns (session_id, cli, ordinal, role, text) '
        'VALUES (?, ?, ?, ?, ?);',
      );
      for (var i = 0; i < 200000; i++) {
        insert.execute([
          'c${i % 5000}',
          'claudeCode',
          i,
          'user',
          corpus.sentence(12),
        ]);
      }
      insert.close();
      raw.execute('COMMIT;');
      final migrate = Stopwatch()..start();
      raw.execute('BEGIN;');
      schemaMigrations[56]!(raw);
      raw.execute('COMMIT;');
      migrate.stop();
      raw.close();

      final mb = bytes / (1024 * 1024);
      // ignore: avoid_print
      print(
        [
          'SESSION SEARCH BENCH (sqlite ${sqlite3.version.libVersion})',
          'corpus: $count transcripts, ${mb.toStringAsFixed(1)} MB, '
              '$turns indexed turns, index db ${(pageSize * pages / (1024 * 1024)).toStringAsFixed(1)} MB',
          'cold build: ${_ms(cold).toStringAsFixed(0)} ms '
              '(DB writes on the calling isolate ${coldWrites.toStringAsFixed(0)} ms)',
          'warm sweep, nothing changed: ${_ms(warm).toStringAsFixed(0)} ms '
              '(${indexer.skips} skips, ${indexer.parses} whole reads)',
          'append sweep: 100 transcripts, $appendBytes bytes appended, '
              '$appendRead bytes read, '
              '${_ms(append).toStringAsFixed(1)} ms '
              '(DB writes ${appendWrites.toStringAsFixed(1)} ms)',
          'queries (20 conversations a page, cascade included):',
          ...lines,
          '  ${'all'.padRight(26)} ${_percentiles(all)}',
          'large transcript: ${(bigSize / (1024 * 1024)).toStringAsFixed(1)} MB, '
              '$bigTurns turns',
          '  first open of the new file (on-access scan): '
              '${_ms(firstOpen).toStringAsFixed(0)} ms',
          '  cold index, after that open: ${_ms(bigCold).toStringAsFixed(0)} ms '
              '(DB writes ${bigColdWrites.toStringAsFixed(0)} ms)',
          '  first open after an append (on-access scan): '
              '${_percentiles(opens)}',
          '  index an append of ${utf8.encode(tick).length} bytes '
              '($bigAppendBytes read): ${_percentiles(ticks)}',
          '    of which DB writes: ${_percentiles(tickWrites)}',
          '  whole re-read it replaced: ${_ms(reread).toStringAsFixed(0)} ms',
          'v56 migration on a 200,000-turn v55 index: '
              '${_ms(migrate).toStringAsFixed(2)} ms',
        ].join('\n'),
      );

      expect(found, greaterThan(0));
      expect(bigAppendBytes, utf8.encode(tick).length);
    },
    skip: enabled ? false : 'set KARMASHALA_SEARCH_BENCH=1 to run',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

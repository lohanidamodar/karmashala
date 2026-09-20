import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/cli_detection/data/store_scan_worker.dart';
import 'package:path/path.dart' as p;

/// **What one CLI-store scan costs, counted.**
///
/// Three claims, and each is a number rather than a duration — milliseconds on
/// a shared machine are noise, and every one of these is deterministic:
///
/// * **Bounded.** No more than [kStoreScanConcurrency] directory reads are
///   alive at once inside a job. Unbounded, the same store reaches its full
///   width, which is what makes the bound about something.
/// * **Addressable.** A caller that knows which working directories it wants
///   reads those Claude directories and no others — measured in bytes off the
///   disk, so a directory that was merely listed and not read still counts as
///   skipped.
/// * **Elsewhere.** The production runner walks the store on a worker isolate,
///   and each chunk says which isolate produced it.
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('karmashala-scan'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// A `.claude` store with one project directory per [cwds] entry, each
  /// holding [perProject] sessions.
  String claudeStore(List<String> cwds, {int perProject = 4}) {
    final home = p.join(temp.path, 'claude-${cwds.length}');
    for (final cwd in cwds) {
      final dir = Directory(
        p.join(home, 'projects', claudeStoreDirectoryName(cwd)),
      )..createSync(recursive: true);
      for (var i = 0; i < perProject; i++) {
        File(
          p.join(dir.path, 'session-$i.jsonl'),
        ).writeAsStringSync('${jsonEncode({'cwd': cwd, 'type': 'user'})}\n');
      }
    }
    return home;
  }

  String codexStore({required int rollouts}) {
    final home = p.join(temp.path, 'codex');
    for (var i = 0; i < rollouts; i++) {
      final dir = Directory(
        p.join(home, 'sessions', '2026', '09', '${(i % 28) + 1}'),
      )..createSync(recursive: true);
      File(
        p.join(dir.path, 'rollout-2026-09-05T00-00-0$i-id$i.jsonl'),
      ).writeAsStringSync(
        '${jsonEncode({
          'type': 'session_meta',
          'payload': {'cwd': r'C:\work', 'id': 'id$i'},
        })}\n',
      );
    }
    return home;
  }

  group('bounded inside a job', () {
    test('a Claude store reads at most kStoreScanConcurrency directories at '
        'once, and reaches its full width without the bound', () async {
      final home = claudeStore([
        for (var i = 0; i < 12; i++)
          r'C:\work\p'
              '$i',
      ]);

      final bounded = StoreScanSlots(concurrency: kStoreScanConcurrency);
      await ClaudeStoreReader(
        cache: ClaudeStoreCache(),
      ).read(home, 'windows', slots: bounded);

      final unbounded = StoreScanSlots(concurrency: 12);
      await ClaudeStoreReader(
        cache: ClaudeStoreCache(),
      ).read(home, 'windows', slots: unbounded);

      // ignore: avoid_print
      print(
        'CLAUDE-SCAN directories=12 bounded=${bounded.peakInFlight} '
        'unbounded=${unbounded.peakInFlight}',
      );
      expect(
        bounded.peakInFlight,
        lessThanOrEqualTo(kStoreScanConcurrency),
        reason: 'the bound is what stops a 12-way burst across a 9p share',
      );
      expect(
        unbounded.peakInFlight,
        greaterThan(kStoreScanConcurrency),
        reason: 'without it the store fans out as wide as it has directories',
      );
    });

    test(
      'a Codex store reads at most kStoreScanConcurrency rollouts at once',
      () async {
        final home = codexStore(rollouts: 12);
        final bounded = StoreScanSlots(concurrency: kStoreScanConcurrency);
        final sessions = await CodexStoreReader(
          cache: CodexRolloutCache(),
        ).read(home, 'windows', slots: bounded);

        expect(sessions, hasLength(12));
        expect(bounded.peakInFlight, lessThanOrEqualTo(kStoreScanConcurrency));
      },
    );
  });

  group('addressable', () {
    test(
      'a working directory encodes to the directory Claude writes it in',
      () {
        // Verified against the owner's two stores on 2026-09-05.
        expect(
          claudeStoreDirectoryName('/mnt/c/Users/dlohani/projects/popupbits'),
          '-mnt-c-Users-dlohani-projects-popupbits',
        );
        expect(claudeStoreDirectoryName(r'C:\'), 'C--');
        expect(
          claudeStoreDirectoryName('/tmp/claude-1000/-mnt-c-x/scratchpad'),
          '-tmp-claude-1000--mnt-c-x-scratchpad',
        );
      },
    );

    test('narrowing reads the named directories and no others', () async {
      final home = claudeStore([r'C:\work\a', r'C:\work\b', r'C:\work\c']);

      final everything = ClaudeStoreReader(cache: ClaudeStoreCache());
      final all = await everything.read(home, 'windows');

      final narrowed = ClaudeStoreReader(cache: ClaudeStoreCache());
      final one = await narrowed.read(
        home,
        'windows',
        directories: {claudeStoreDirectoryName(r'C:\work\b').toLowerCase()},
      );

      // ignore: avoid_print
      print(
        'CLAUDE-NARROW all=${all.length}/${everything.bytesRead}B '
        'one=${one.length}/${narrowed.bytesRead}B',
      );
      expect(all, hasLength(12));
      expect(one, hasLength(4));
      expect(one.map((s) => s.cwd.path).toSet(), {r'C:\work\b'});
      expect(
        narrowed.bytesRead * 3,
        everything.bytesRead,
        reason: 'a third of the store, because two directories were never read',
      );
    });

    test(
      'the match is case-insensitive, because Claude preserves case',
      () async {
        // Both `G--dev-…` and `g--dev-…` exist in the owner's Windows store.
        final home = claudeStore([r'g:\dev\x']);
        final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
        final found = await reader.read(
          home,
          'windows',
          directories: {claudeStoreDirectoryName(r'G:\dev\x').toLowerCase()},
        );
        expect(found, hasLength(4));
      },
    );
  });

  group('elsewhere', () {
    test('the worker isolate is what walks the store, and says so', () async {
      final home = claudeStore([r'C:\work\a'], perProject: 2);
      final runner = IsolateStoreScanRunner();
      addTearDown(runner.shutdown);

      expect(
        runner.isWorkerRunning,
        isFalse,
        reason: 'created on first use, so a launch that never scans pays none',
      );

      final chunks = await runner
          .scan(
            StoreScanRequest(
              stores: [
                CliStore(
                  environmentId: 'windows',
                  homesByAgentId: {AgentIds.claudeCode: home},
                ),
              ],
            ),
          )
          .toList();

      expect(runner.isWorkerRunning, isTrue);
      expect(chunks, hasLength(1));
      expect(chunks.single.sessions, hasLength(2));
      expect(
        chunks.single.isolate,
        kStoreScanIsolateName,
        reason: 'the whole point: not the isolate that draws',
      );
    });

    test('jobs are agent-major, Claude before Codex', () async {
      final claude = claudeStore([r'C:\work\a'], perProject: 1);
      final codex = codexStore(rollouts: 1);
      final chunks = await InlineStoreScanRunner()
          .scan(
            StoreScanRequest(
              stores: [
                CliStore(
                  environmentId: 'windows',
                  homesByAgentId: {
                    AgentIds.codex: codex,
                    AgentIds.claudeCode: claude,
                  },
                ),
              ],
            ),
          )
          .toList();

      expect(chunks.map((c) => c.agentId).toList(), [
        AgentIds.claudeCode,
        AgentIds.codex,
      ], reason: 'Claude is addressable and cheap; Codex must open every file');
      // Each job answers on its own, so Claude's rows are usable while Codex
      // is still walking.
      expect(chunks.every((c) => c.sessions.length == 1), isTrue);
    });
  });
}

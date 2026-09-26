import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/server_verification_runs.dart';
import 'package:karmashala_host/src/mcp/tools/verification_tool_set.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show DecisionRecordDao;
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/tools.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The blocks of an `_mcpContent` result.
List<Map<String, Object?>> blocks(Object? result) => [
  for (final block in (result! as Map)['_mcpContent']! as List)
    Map<String, Object?>.from(block as Map),
];

/// The text of the one text block.
String textOf(Object? result) =>
    blocks(result).firstWhere((b) => b['type'] == 'text')['text']! as String;

/// `verification_*` as the server runs them: a review of a change recorded
/// here, over a real store and data service, and the calls it hands to the
/// app because only the app drives a browser or a device.
void main() {
  late AppDatabase db;
  late DataService data;
  late ServerToolContext context;
  late ServerVerificationRuns runs;
  late VerificationToolSet tools;
  late Directory dataDirectory;
  late List<DataChanges> told;
  final now = DateTime.utc(2026, 9, 27, 12);
  var ids = 0;

  setUp(() {
    db = AppDatabase.memory();
    data = DataService(db, clock: () => now);
    told = [];
    data.open(told.add).handle(const DataSubscribe());
    dataDirectory = Directory.systemTemp.createTempSync('verify-server');
    context = ServerToolContext(
      database: db,
      data: data,
      dataDirectory: dataDirectory.path,
      clock: () => now,
    );
    ids = 0;
    runs = ServerVerificationRuns(
      context,
      newId: () => 'run-${(++ids).toString().padLeft(3, '0')}',
    );
    tools = VerificationToolSet(runs);

    const at = '2026-01-01T00:00:00.000Z';
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('windows', 'windowsNative', 'Windows', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO projects '
      '(id, name, root_environment_id, root_path, created_at) '
      "VALUES ('p1', 'Demo', 'windows', 'C:\\src', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO repositories '
      '(id, project_id, name, environment_id, path, created_at) '
      "VALUES ('r1', 'p1', 'r1', 'windows', 'C:\\src', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('a1', 'claudeCode', 'windows', 'claude', ?);",
      [at],
    );
    for (final id in ['work-1', 'review-1']) {
      data
          .open((_) {})
          .handle(
            SessionCreate(
              Session(
                id: id,
                repositoryId: 'r1',
                agentInstallationId: 'a1',
                title: id,
                useWorktree: false,
                status: SessionStatus.created,
                createdAt: now,
              ),
            ),
          );
    }
  });
  tearDown(() {
    context.close();
    db.close();
    if (dataDirectory.existsSync()) dataDirectory.deleteSync(recursive: true);
  });

  Future<Object?> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
    String? caller,
  ]) => tools.call(tool, arguments, caller)!;

  Matcher refusal(String words) => throwsA(
    isA<VerificationException>().having(
      (e) => e.message,
      'message',
      contains(words),
    ),
  );

  group('what the server hands to the app', () {
    test('a page or a device run drives the app, so its start is the '
        'app\'s', () {
      expect(
        tools.call('verification_start', {'url': 'https://a.test'}, 's'),
        isNull,
      );
      expect(
        tools.call('verification_start', {
          'serial': 'FAKE123',
          'package': 'com.example.app',
        }, 's'),
        isNull,
      );
    });

    test('note, finish and a get with no id mean the app\'s run while the '
        'server records nothing', () {
      expect(tools.call('verification_note', {'text': 'x'}, 's'), isNull);
      expect(
        tools.call('verification_finish', {'verdict': 'pass'}, 's'),
        isNull,
      );
      expect(tools.call('verification_get', const {}, 's'), isNull);
    });

    test('a list and a get by id are read here', () async {
      expect(
        textOf(await call('verification_list')),
        contains('No verification'),
      );
      await expectLater(
        call('verification_get', {'id': 'nope'}),
        refusal('No verification run with id (or prefix) "nope".'),
      );
    });

    test('while the server records, every start is its refusal, and note, '
        'finish and get are its own', () async {
      await call('verification_start', {'change': true, 'title': 'A'});
      await expectLater(
        call('verification_start', {'url': 'https://a.test'}),
        refusal(
          'A verification run is already recording: "A" (run-001). '
          'Finish it before starting another.',
        ),
      );
      expect(tools.call('verification_note', {'text': 'x'}, null), isNotNull);
      expect(
        textOf(await call('verification_get')),
        contains('STILL RECORDING'),
      );
    });
  });

  group('verification_start', () {
    test('change:true records the caller as the verifier', () async {
      final result = await call('verification_start', {
        'change': true,
        'sessionId': 'work-1',
        'title': 'Review of the parser fix',
      }, 'review-1');
      final run = runs.activeRun!;
      expect(run.target.kind, VerificationTargetKind.change);
      expect(run.sessionId, 'work-1');
      expect(run.producedBySessionId, 'review-1');
      expect(textOf(result), contains('Recording run-001'));
      expect(textOf(result), contains('independent'));
      expect(textOf(result), contains('verification_note'));
      // Every client is told, and the evidence folder is the server's.
      expect(
        told.expand((t) => t.changes).whereType<VerificationRunChanged>(),
        isNotEmpty,
      );
      expect(
        run.artifactDirectory,
        p.join(dataDirectory.path, 'verification', 'run-001'),
      );
      expect(Directory(run.artifactDirectory).existsSync(), isTrue);
    });

    test('with no subject the caller graded itself, and says so', () async {
      await call('verification_start', {'change': true}, 'work-1');
      expect(runs.activeRun!.sessionId, 'work-1');
      expect(runs.activeRun!.attribution, VerdictAttribution.author);
      expect(runs.activeRun!.title, 'Review of the change');
    });

    test('a change run cannot also be a page run', () async {
      await expectLater(
        call('verification_start', {'change': true, 'url': 'localhost:3000'}),
        refusal(
          'A run verifies one thing: pass url, serial or change, not '
          'several.',
        ),
      );
      await expectLater(
        call('verification_start', {
          'url': 'https://a.test',
          'serial': 'FAKE123',
        }),
        refusal('A run verifies one thing'),
      );
    });

    test('naming nothing at all points at all three kinds', () async {
      await expectLater(
        call('verification_start'),
        refusal(
          'Give url (to verify a page), serial (to verify a device), or '
          'change:true (to record a review of the code itself). list_devices '
          'has the serials.',
        ),
      );
    });
  });

  group('verification_note and finish', () {
    test('a note needs something to say', () async {
      await call('verification_start', {'change': true});
      await expectLater(
        call('verification_note', {'text': '   '}),
        refusal('text is required.'),
      );
    });

    test('an unknown verdict lists the ones that exist', () async {
      await call('verification_start', {'change': true});
      await expectLater(
        call('verification_finish', {'verdict': 'maybe'}),
        refusal('verdict must be one of: pass, fail, inconclusive.'),
      );
    });

    test('finishing reports the verdict, writes the report and frees the '
        'slot', () async {
      await call('verification_start', {
        'change': true,
        'sessionId': 'work-1',
        'title': 'Review of the parser fix',
      }, 'review-1');
      await call('verification_note', {
        'text': 'The retry loop never resets the counter.',
      }, 'review-1');
      final text = textOf(
        await call('verification_finish', {
          'verdict': 'fail',
          'reason': 'The retry loop never resets its counter.',
        }, 'review-1'),
      );
      expect(text, startsWith('FAIL — Review of the parser fix'));
      expect(text, contains('by another session'));
      expect(text, contains('1 step'));
      final report = File(
        p.join(dataDirectory.path, 'verification', 'run-001', 'report.md'),
      );
      expect(text, contains('Report: ${report.path}'));
      expect(report.readAsStringSync(), contains('**Verdict: FAIL**'));
      expect(runs.activeRun, isNull);

      final stored = (await runs.get('run-001'))!;
      expect(stored.verdict, VerificationVerdict.fail);
      expect(stored.attribution, VerdictAttribution.independent);
      expect(stored.steps.single.kind, VerificationStepKind.note);
    });

    test('a pass the session gave itself says it is self-verified', () async {
      await call('verification_start', {'change': true}, 'work-1');
      final text = textOf(
        await call('verification_finish', {'verdict': 'pass'}, 'work-1'),
      );
      expect(text, contains('SELF-VERIFIED'));
      expect(text, contains('checks_run'));
    });

    test('a caller outside a session leaves the run unattributed', () async {
      await call('verification_start', {'change': true});
      await call('verification_finish', {'verdict': 'pass'});
      final run = (await runs.list()).single;
      expect(run.producedBySessionId, isNull);
      expect(run.attribution, VerdictAttribution.notRecorded);
    });
  });

  group('the verdict lands in the decision record', () {
    test('of the session whose work it judged, named by its agent', () async {
      await call('verification_start', {
        'change': true,
        'sessionId': 'work-1',
        'title': 'Review of the trailing-comma fix',
      }, 'review-1');
      await call('verification_finish', {
        'verdict': 'pass',
        'reason': 'Nothing wrong found.',
      }, 'review-1');

      final decision = DecisionRecordDao(db).forSession('work-1').single;
      expect(decision.kind, DecisionKind.verificationVerdict);
      expect(
        decision.summary,
        '${VerificationVerdict.pass.label} — Review of the trailing-comma '
        'fix. Nothing wrong found.',
      );
      expect(
        decision.detail,
        'Verdict ${VerdictAttribution.independent.phrase}.',
      );
      expect(decision.decidedBy, 'Claude Code');
      expect(decision.recordedBySessionId, 'review-1');
      expect(decision.origin, DecisionOrigin.verificationRun);
      expect(decision.originId, 'run-001');
      expect(DecisionRecordDao(db).forSession('review-1'), isEmpty);
      expect(
        told.expand((t) => t.changes).whereType<DecisionRecorded>(),
        isNotEmpty,
      );
    });

    test('an unattached run writes nothing, and a missing subject does not '
        'fail the finish', () async {
      await call('verification_start', {'change': true});
      await call('verification_finish', {'verdict': 'pass'});
      await call('verification_start', {'change': true, 'sessionId': 'gone'});
      final text = textOf(
        await call('verification_finish', {'verdict': 'fail'}),
      );
      expect(text, startsWith('FAIL'));
      expect(DecisionRecordDao(db).all(), isEmpty);
    });
  });

  group('reading', () {
    test('one line per run, newest first, and no JSON', () async {
      await call('verification_start', {'change': true, 'title': 'older run'});
      await call('verification_finish', {'verdict': 'pass'});
      await call('verification_start', {'change': true, 'title': 'newer run'});
      await call('verification_note', {'text': 'looked'});
      await call('verification_finish', {'verdict': 'fail'});

      final result = await call('verification_list');
      final text = textOf(result);
      expect(blocks(result), hasLength(1));
      expect(text, isNot(contains('{')));
      expect(text.indexOf('newer run'), lessThan(text.indexOf('older run')));
      expect(text, contains('FAIL'));
      expect(text, contains('1 step'));
    });

    test('a prefix works, and an ambiguous one lists the candidates', () async {
      await call('verification_start', {'change': true, 'title': 'one'});
      await call('verification_finish', {'verdict': 'pass'});
      await call('verification_start', {'change': true, 'title': 'two'});
      await call('verification_finish', {'verdict': 'pass'});

      expect(
        textOf(await call('verification_get', {'id': 'run-001'})),
        contains('one'),
      );
      await expectLater(
        call('verification_get', {'id': 'run-'}),
        refusal('matches 2 runs'),
      );
    });

    test('a run the app recorded is read here by id', () async {
      data
          .open((_) {})
          .handle(
            VerificationStart(
              VerificationRun(
                id: 'run-app',
                title: 'the page saves',
                target: const VerificationTarget.browser('https://a.test'),
                startedAt: now,
                artifactDirectory: p.join(dataDirectory.path, 'verification'),
              ),
            ),
          );
      expect(
        textOf(await call('verification_get', {'id': 'run-app'})),
        contains('STILL RECORDING — the page saves'),
      );
    });
  });
}

import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/check_results.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/store.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 10, 1, 12);

const _broken = TestCaseResult(
  suite: 'a_test.dart',
  name: 'breaks',
  outcome: TestOutcome.failed,
);

CheckResults _tests({bool failing = false}) => CheckResults(
  format: CheckOutputFormat.testJson,
  tests: [
    const TestCaseResult(
      suite: 'a_test.dart',
      name: 'passes',
      outcome: TestOutcome.passed,
    ),
    if (failing) _broken,
  ],
  passed: 1,
  failed: failing ? 1 : 0,
);

RecordedCheckResults _reading({
  required DateTime at,
  String? directory = '/repo',
  String? sessionId,
  bool failing = false,
}) => RecordedCheckResults(
  repositoryId: 'r1',
  checkName: 'test',
  recordedAt: at,
  directory: directory,
  sessionId: sessionId,
  results: _tests(failing: failing),
);

void main() {
  late AppDatabase db;
  late CheckResultDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = CheckResultDao(db, keepPerCheck: 3);
  });
  tearDown(() => db.close());

  test('keeps failures and counts, not passing tests', () {
    dao.record(_reading(at: _t0, sessionId: 's1', failing: true));
    final kept = dao.forSession('s1').single.results;
    expect(kept.tests.map((t) => t.name), ['breaks']);
    expect(kept.passed, 1);
    expect(kept.failed, 1);
  });

  test('a baseline is taken in the same directory only', () {
    dao.record(_reading(at: _t0, directory: '/repo/.wt/a', sessionId: 'a'));
    dao.record(_reading(at: _t0, directory: '/repo/', sessionId: 'old'));

    final found = dao.latestBefore(
      repositoryId: 'r1',
      checkName: 'test',
      before: _t0.add(const Duration(hours: 1)),
      directory: '/repo',
      excludingSessionId: 's2',
    );
    expect(found?.sessionId, 'old');
    expect(found?.directory, '/repo');
  });

  test('with none in its directory, the session\'s own first reading is '
      'the baseline, and the label says so', () {
    dao.record(_reading(at: _t0, directory: '/repo', sessionId: 'other'));
    final start = _t0.add(const Duration(minutes: 1));
    dao.record(
      _reading(
        at: start.add(const Duration(minutes: 1)),
        directory: '/repo/.wt/b',
        sessionId: 'b',
      ),
    );

    final change = changeAgainstBaseline(
      dao,
      repositoryId: 'r1',
      checkName: 'test',
      current: _tests(failing: true),
      sessionStartedAt: start,
      directory: '/repo/.wt/b',
      sessionId: 'b',
    )!;
    expect(change.baselineLabel, contains("this session's first reading"));
    expect(change.baselineLabel, contains('/repo/.wt/b'));
    expect(change.brokenTests.map((t) => t.name), ['breaks']);
  });

  test('each check keeps its newest readings and the sessions\' first', () {
    for (var i = 0; i < 6; i++) {
      dao.record(
        _reading(
          at: _t0.add(Duration(minutes: i)),
          sessionId: 's1',
        ),
      );
    }
    dao.record(
      _reading(at: _t0.add(const Duration(minutes: 9)), directory: '/other'),
    );

    final kept = dao.forSession('s1');
    expect(kept.length, 4);
    expect(kept.first.recordedAt, _t0);
    expect(kept.last.recordedAt, _t0.add(const Duration(minutes: 5)));
  });
}

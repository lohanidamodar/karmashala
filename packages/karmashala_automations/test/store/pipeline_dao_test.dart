import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/verification.dart' show CodeIdentity;
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late PipelineDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = PipelineDao(db);
  });
  tearDown(() => db.close());

  final at = DateTime.utc(2026, 10, 9, 8);

  test('a saved pipeline is never stored as built in', () {
    final template = kPipelineTemplates.first;
    dao.saveDefinition(template.copyWith(id: 'mine', name: 'Mine'), at);
    final saved = dao.definition('mine')!;
    expect(saved.builtIn, isFalse);
    expect(saved.stages, template.stages);
    dao.saveDefinition(saved.copyWith(name: 'Renamed'), at);
    expect(dao.definitions().map((d) => d.name), ['Renamed']);
    dao.deleteDefinition('mine');
    expect(dao.definitions(), isEmpty);
  });

  test('a run keeps every stage record, its check and identity', () {
    final run = PipelineRun(
      id: 'r1',
      definition: kPipelineTemplates[1],
      repositoryId: 'repo',
      input: 'fix the cart',
      state: PipelineRunState.running,
      createdAt: at,
      updatedAt: at,
      startedBySessionId: 'parent',
      records: [
        PipelineStageRecord(
          stageIndex: 1,
          role: 'Test',
          attempt: 2,
          state: PipelineStageState.checking,
          sessionId: 's2',
          answer: 'VERDICT: PASS',
          artifacts: const [
            PipelineArtifactRef(id: 'a', title: 'report', path: '/r.md'),
          ],
          worktreePath: '/wt',
          environmentId: 'local',
          branch: 'b',
          startedAt: at,
          check: PipelineCheckRecord(
            verdict: VerificationVerdict.pass,
            summary: 'ok',
            checkedAt: at,
            verificationRunId: 'v1',
            identity: const CodeIdentity(
              environmentId: 'local',
              path: '/wt',
              head: 'abcdef1234',
              tree: 't',
              changedDuringRun: true,
            ),
          ),
        ),
      ],
    );
    dao.putRun(run);
    expect(dao.active().single.id, 'r1');
    final read = dao.run('r1')!;
    final record = read.current!;
    expect(read.startedBySessionId, 'parent');
    expect(record.attempt, 2);
    expect(record.state, PipelineStageState.checking);
    expect(record.artifacts.single.answersTo('R.MD'), isTrue);
    expect(record.check!.identity!.head, 'abcdef1234');
    expect(record.check!.stale, isTrue);
    expect(record.check!.passed, isFalse, reason: 'a stale pass is no pass');

    dao.putRun(read.copyWith(state: PipelineRunState.finished));
    expect(dao.active(), isEmpty);
    expect(dao.runs().single.state, PipelineRunState.finished);
  });
}

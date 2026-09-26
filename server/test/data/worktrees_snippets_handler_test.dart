import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The git side tables, snippets and presets at the server: the rules each
/// write follows, and what every other client is told.
void main() {
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  var now = DateTime.utc(2026, 9, 27, 12);

  setUp(() {
    now = DateTime.utc(2026, 9, 27, 12);
    db = AppDatabase.memory();
    service = DataService(db, clock: () => now);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    final at = now.toIso8601String();
    db
      ..execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        "VALUES ('windows', 'windowsNative', 'Windows', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO projects (id, name, root_environment_id, root_path, '
        "created_at) VALUES ('p1', 'App', 'windows', 'C:\\src', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO repositories '
        '(id, project_id, name, environment_id, path, created_at) '
        "VALUES ('r1', 'p1', 'app', 'windows', 'C:\\src', ?);",
        [at],
      );
  });
  tearDown(() => db.close());

  Matcher refused(DataRefusalCode code) =>
      throwsA(isA<DataRefused>().having((r) => r.code, 'code', code));

  List<DataChange> lastTold() => told.last.changes;

  group('worktree setup', () {
    test('a save is told; one that asks for nothing clears', () {
      const setup = WorktreeSetup(command: ['make'], teardown: ['down']);
      app.handle(const WorktreeSetupSave('r1', setup));
      final changed = lastTold().single as WorktreeSetupChanged;
      expect(changed.setup, setup);
      expect(app.handle(const WorktreesList()).value.setups['r1'], setup);

      app.handle(const WorktreeSetupSave('r1', WorktreeSetup()));
      expect((lastTold().single as WorktreeSetupChanged).setup, isNull);
      expect(app.handle(const WorktreesList()).value.setups, isEmpty);
    });

    test('an unknown checkout is refused', () {
      expect(
        () => app.handle(const WorktreeSetupClear('nope')),
        refused(DataRefusalCode.notFound),
      );
    });

    test('a run is recorded once per worktree, from a client or the '
        'server itself', () {
      WorktreeSetupReport report(DateTime at) => WorktreeSetupReport(
        repositoryId: 'r1',
        worktreePath: r'C:\w\one',
        environmentId: 'windows',
        ranAt: at,
        copies: const [],
      );
      app.handle(WorktreeSetupRecord(report(now)));
      expect(lastTold().single, isA<WorktreeRunRecorded>());
      final before = told.length;
      service.recordWorktreeSetup(report(now.add(const Duration(minutes: 1))));
      expect(told, hasLength(before + 1), reason: 'the server tells its own');
      final runs = app.handle(const WorktreesList()).value.runs;
      expect(runs.single.ranAt, now.add(const Duration(minutes: 1)));
    });
  });

  group('a checkout that goes', () {
    void seed() {
      app
        ..handle(
          const WorktreeSetupSave(
            'r1',
            WorktreeSetup(command: ['make'], teardown: ['down']),
          ),
        )
        ..handle(
          WorktreeSetupRecord(
            WorktreeSetupReport(
              repositoryId: 'r1',
              worktreePath: r'C:\w\one',
              environmentId: 'windows',
              ranAt: now,
              copies: const [],
            ),
          ),
        )
        ..handle(
          const ReviewThreadOpen(
            id: 't1',
            repositoryId: 'r1',
            anchor: ReviewAnchor(path: 'a.dart', blobSha: 'sha', startLine: 1),
            author: 'me',
            authorKind: ReviewAuthorKind.user,
            body: 'fix',
          ),
        );
    }

    void expectCascadeTold(List<DataChange> changes) {
      expect(changes.whereType<WorktreeSetupChanged>().single.setup, isNull);
      expect(changes.whereType<WorktreeRunRemoved>(), hasLength(1));
      expect(changes.whereType<ReviewThreadRemoved>().single.id, 't1');
      final left = app.handle(const WorktreesList()).value;
      expect(left.setups, isEmpty);
      expect(left.runs, isEmpty);
      expect(left.threads, isEmpty);
      expect(
        db.query(
          "SELECT key FROM app_metadata WHERE key LIKE 'worktree_setup.%' "
          "AND value LIKE '%r1%';",
        ),
        isEmpty,
        reason: 'the teardown the cascade does not reach is cleared too',
      );
    }

    test('with its project, its setup, runs and threads are told gone', () {
      seed();
      app.handle(const ProjectDelete('p1'));
      expectCascadeTold(lastTold());
    });

    test('retired, the same', () {
      seed();
      app.handle(const CheckoutsRetire(['r1']));
      expectCascadeTold(lastTold());
    });
  });

  group('review threads', () {
    ReviewThread open({
      String id = 't1',
      ReviewAuthorKind kind = ReviewAuthorKind.agent,
      String body = ' wrong ',
    }) => app
        .handle(
          ReviewThreadOpen(
            id: id,
            repositoryId: 'r1',
            anchor: const ReviewAnchor(
              path: 'a.dart',
              blobSha: 'sha',
              startLine: 3,
            ),
            author: 'me',
            authorKind: kind,
            body: body,
          ),
        )
        .value;

    test('opened with its first comment, trimmed; the status by author', () {
      final thread = open();
      expect(thread.body, 'wrong');
      expect(thread.status, ReviewThreadStatus.open);
      expect(thread.anchor.endLine, 3, reason: 'one line is stored twice');
      expect(
        open(id: 't2', kind: ReviewAuthorKind.user).status,
        ReviewThreadStatus.shouldFix,
      );
      expect(lastTold().single, isA<ReviewThreadChanged>());
    });

    test('a blank body, a taken id and an unknown checkout are refused', () {
      open();
      expect(
        () => open(id: 't9', body: '  '),
        refused(DataRefusalCode.invalid),
      );
      expect(() => open(), refused(DataRefusalCode.invalid));
    });

    test('a reply and a status move the thread and are told', () {
      open();
      now = now.add(const Duration(minutes: 5));
      final replied = app
          .handle(
            const ReviewThreadReply(
              threadId: 't1',
              author: 'me',
              authorKind: ReviewAuthorKind.user,
              body: 'still',
            ),
          )
          .value;
      expect(replied.comments, hasLength(2));
      expect(replied.updatedAt, now);
      final moved = app
          .handle(
            const ReviewThreadSetStatus('t1', ReviewThreadStatus.resolved),
          )
          .value;
      expect(moved.status, ReviewThreadStatus.resolved);
      expect(
        (lastTold().single as ReviewThreadChanged).thread.status,
        ReviewThreadStatus.resolved,
      );
      expect(
        () => app.handle(
          const ReviewThreadSetStatus('t1', ReviewThreadStatus.unrecognised),
        ),
        refused(DataRefusalCode.invalid),
      );
      expect(
        () => app.handle(
          const ReviewThreadReply(
            threadId: 'gone',
            author: 'me',
            authorKind: ReviewAuthorKind.user,
            body: 'x',
          ),
        ),
        refused(DataRefusalCode.notFound),
      );
      expect(app.handle(const WorktreesList()).value.threads, hasLength(1));
    });
  });

  group('snippets', () {
    test('added one line, trimmed and stamped; edited keeping creation', () {
      final added = app
          .handle(
            const SnippetAdd(
              id: 's1',
              label: ' Build ',
              command: 'make\nbuild',
              shellId: 'wsl',
            ),
          )
          .value;
      expect(added.label, 'Build');
      expect(added.command, 'make build');
      expect(added.createdAt, now);
      expect(lastTold().single, isA<SnippetChanged>());

      now = now.add(const Duration(hours: 1));
      final edited = app
          .handle(
            const SnippetEdit(id: 's1', label: 'B', command: 'm', submit: true),
          )
          .value;
      expect(edited.shellId, isNull);
      expect(edited.submit, isTrue);
      expect(edited.createdAt, added.createdAt);
      expect(edited.updatedAt, now);
    });

    test('a blank one, a taken id and an unknown one are refused', () {
      expect(
        () => app.handle(const SnippetAdd(id: 's', label: ' ', command: 'x')),
        refused(DataRefusalCode.invalid),
      );
      app.handle(const SnippetAdd(id: 's', label: 'l', command: 'x'));
      expect(
        () => app.handle(const SnippetAdd(id: 's', label: 'l', command: 'x')),
        refused(DataRefusalCode.invalid),
      );
      expect(
        () => app.handle(const SnippetEdit(id: 'n', label: 'l', command: 'x')),
        refused(DataRefusalCode.notFound),
      );
    });

    test('a delete is told once; a second is nothing', () {
      app.handle(const SnippetAdd(id: 's', label: 'l', command: 'x'));
      app.handle(const SnippetDelete('s'));
      expect(lastTold().single, isA<SnippetRemoved>());
      final before = told.length;
      app.handle(const SnippetDelete('s'));
      expect(told, hasLength(before));
      expect(app.handle(const SnippetsList()).value.snippets, isEmpty);
    });
  });

  group('presets', () {
    const shape = {
      'tabs': [
        {'panes': <Object?>[]},
      ],
      'active': 0,
    };

    test('a name already saved is replaced under its id', () {
      final first = app
          .handle(const PresetSave(id: 'p1', presetName: ' Two ', shape: shape))
          .value;
      expect(first.name, 'Two');
      final again = app
          .handle(const PresetSave(id: 'p2', presetName: 'Two', shape: shape))
          .value;
      expect(again.id, 'p1');
      expect(app.handle(const SnippetsList()).value.presets, hasLength(1));
      expect((lastTold().single as PresetChanged).preset.id, 'p1');
      app.handle(const PresetDelete('p1'));
      expect(lastTold().single, isA<PresetRemoved>());
    });

    test('a blank name or no shape is refused', () {
      expect(
        () => app.handle(
          const PresetSave(id: 'p', presetName: ' ', shape: shape),
        ),
        refused(DataRefusalCode.invalid),
      );
      expect(
        () => app.handle(const PresetSave(id: 'p', presetName: 'x', shape: {})),
        refused(DataRefusalCode.invalid),
      );
    });
  });
}

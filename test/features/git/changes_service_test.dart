import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/git/application/changes_service.dart';
import 'package:chitragupta/src/features/git/domain/file_change.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late FakeCommandRunner runner;
  late ChangesService service;

  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\app');

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    runner = FakeCommandRunner(
      responder: (req) {
        if (req.arguments.contains('status')) {
          return const CommandResult(
            exitCode: 0,
            stdout: ' M a.dart\n?? b.dart\n',
            stderr: '',
          );
        }
        return const CommandResult(
          exitCode: 0,
          stdout: '@@ -1 +1 @@\n-old\n+new\n',
          stderr: '',
        );
      },
    );
    service = ChangesService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: ExecutionEnvironmentDao(db),
    );
  });
  tearDown(() => db.close());

  test('changes runs git status and parses results', () async {
    final changes = await service.changes(repo);
    expect(changes.map((c) => c.path), ['a.dart', 'b.dart']);
    expect(changes[1].type, FileChangeType.untracked);
    expect(runner.requests.first.arguments, [
      '-C',
      r'C:\app',
      'status',
      '--porcelain=v1',
    ]);
  });

  test('diff runs git diff scoped to the file', () async {
    final diff = await service.diff(repo, path: 'a.dart');
    expect(diff, contains('+new'));
    expect(runner.requests.single.arguments, [
      '-C',
      r'C:\app',
      'diff',
      '--',
      'a.dart',
    ]);
  });
}

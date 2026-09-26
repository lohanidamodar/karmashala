import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/explorer/application/checkout_picker.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// **What `checkoutLabelsProvider` costs, in processes.**
///
/// The loop was sequential on purpose: its dedup is the whole reason a project
/// of sixty-nine checkouts costs a handful of `git worktree list` calls rather
/// than sixty-nine, and it worked *because* the answers arrived in order. So
/// making it concurrent had to keep the count and only lose the waiting — which
/// is a claim about processes, and is counted here rather than timed.
const _hub = r'C:\src\demo';
const _app = r'C:\src\demo\projects\app';
const _relay = r'C:\src\demo\projects\wt-relay';
const _inbox = r'C:\src\demo\projects\wt-inbox';

/// A `.git` that tells a clone from a worktree the way git itself does: a
/// directory for the first, a `gitdir:` pointer for the second.
class _FamilyFiles implements GitFiles {
  int reads = 0;

  @override
  Future<PathEntry> typeOf(String path) async {
    reads++;
    if (!path.endsWith(r'\.git')) return PathEntry.none;
    final checkout = path.substring(0, path.length - 5);
    if (checkout == _hub || checkout == _app) return PathEntry.directory;
    if (checkout == _relay || checkout == _inbox) return PathEntry.file;
    return PathEntry.none;
  }

  @override
  Future<String?> readString(String path) async {
    reads++;
    if (!path.endsWith(r'\.git')) return null;
    final name = path.split(r'\')[path.split(r'\').length - 2];
    // Both `wt-*` folders are worktrees of the `app` clone, so both name its
    // git directory — which is what makes them one family.
    return 'gitdir: $_app\\.git\\worktrees\\$name\n';
  }

  @override
  Future<bool> exists(String path) async => throw UnimplementedError();

  @override
  Future<void> createDirectory(String path) => throw UnimplementedError();

  @override
  Future<void> writeString(String path, String contents) =>
      throw UnimplementedError();
}

/// A runner that answers nothing until it is told to, so "how many are in
/// flight at once" can be *counted* rather than inferred from a clock.
class _GatedRunner extends FakeCommandRunner {
  final List<Completer<void>> _gates = [];
  var _holding = true;

  /// Calls begun, and calls that have answered. Concurrency is the gap.
  int begun = 0;
  int answered = 0;

  List<String> get worktreeListDirectories => [
    for (final request in requests)
      if (request.arguments.skip(2).take(2).join(' ') == 'worktree list')
        request.arguments.length > 1 ? request.arguments[1] : '',
  ];

  @override
  Future<CommandResult> run(CommandRequest request) async {
    requests.add(request);
    begun++;
    if (_holding) {
      final gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
    }
    answered++;
    final dir = request.arguments.length > 1 ? request.arguments[1] : '';
    if (request.arguments.skip(2).take(2).join(' ') != 'worktree list') {
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    // The clone owns both `wt-*` folders and says so whichever is asked; the
    // hub is a family of one.
    return CommandResult(
      exitCode: 0,
      stdout: dir == _hub
          ? 'worktree C:/src/demo\nHEAD aaa\nbranch refs/heads/main\n\n'
          : 'worktree C:/src/demo/projects/app\n'
                'HEAD bbb\nbranch refs/heads/main\n\n'
                'worktree C:/src/demo/projects/wt-relay\n'
                'HEAD ccc\nbranch refs/heads/dual-relay\n\n'
                'worktree C:/src/demo/projects/wt-inbox\n'
                'HEAD ddd\nbranch refs/heads/inbox-bounds\n\n',
      stderr: '',
    );
  }

  /// Lets everything begun so far answer, and anything begun after this.
  void release() {
    _holding = false;
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
  }
}

void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late _GatedRunner git;

  setUp(() {
    db = AppDatabase.memory();
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project(id: 'p1', name: 'Demo', path: _hub));
    git = _GatedRunner();
  });
  tearDown(() => db.close());

  void insert(List<(String, String)> rows) {
    final dao = server.repositoryRows;
    for (final (id, path) in rows) {
      dao.insert(repository(id: id, name: id, path: path));
    }
  }

  Future<ProviderContainer> containerWith(GitFiles files) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        gitFilesProvider.overrideWithValue(files),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Drives the provider to the point where every process it is going to start
  /// has started, without letting any of them answer.
  Future<Future<Map<String, CheckoutLabel>>> inFlight(
    ProviderContainer container,
  ) async {
    final labels = container.read(checkoutLabelsProvider('p1').future);
    await pumpEventQueue();
    return labels;
  }

  group('grouped by family, then asked once per group', () {
    test('N checkouts of one repository cost exactly one '
        '`git worktree list`', () async {
      insert([('app', _app), ('relay', _relay), ('inbox', _inbox)]);
      final container = await containerWith(_FamilyFiles());

      final labels = await inFlight(container);
      expect(git.worktreeListDirectories, [
        _app,
      ], reason: 'three rows, one family, one process');
      git.release();

      final result = await labels;
      expect(result['app']!.isWorktree, isFalse);
      expect(result['relay']!.isWorktree, isTrue);
      expect(result['relay']!.branch, 'dual-relay');
      expect(result['relay']!.ownerRepositoryId, 'app');
      expect(result['inbox']!.isWorktree, isTrue);
    });

    test('two families are asked at once, not one after the other', () async {
      insert([
        ('hub', _hub),
        ('app', _app),
        ('relay', _relay),
        ('inbox', _inbox),
      ]);
      final container = await containerWith(_FamilyFiles());

      final labels = await inFlight(container);
      // Four rows, two families, two processes — and both are in flight before
      // either has answered, which is the whole of the change.
      expect(git.worktreeListDirectories, hasLength(2));
      expect(git.worktreeListDirectories, containsAll([_hub, _app]));
      expect(git.begun, 2);
      expect(git.answered, 0);
      git.release();

      final result = await labels;
      expect(result['hub']!.isWorktree, isFalse);
      expect(result['app']!.isWorktree, isFalse);
      expect(result['relay']!.ownerRepositoryId, 'app');
    });
  });

  group('a row whose family cannot be read keeps the old sequential pass', () {
    test('the dedup survives, one process at a time', () async {
      // What an SSH checkout looks like from here: no path this process can
      // open, so no key — and grouping each unknown row on its own would turn
      // the one saving in this provider into a process per row.
      insert([
        ('hub', _hub),
        ('app', _app),
        ('relay', _relay),
        ('inbox', _inbox),
      ]);
      final container = await containerWith(noGitFiles);

      final labels = await inFlight(container);
      // One at a time, exactly as before: the second is not begun until the
      // first has answered, because its answer may cover the row.
      expect(git.begun, 1);
      expect(git.answered, 0);
      git.release();

      final result = await labels;
      // And still two processes for four rows — the dedup the sequential walk
      // exists for.
      expect(git.worktreeListDirectories, hasLength(2));
      expect(git.worktreeListDirectories, containsAll([_hub, _app]));
      expect(result['relay']!.isWorktree, isTrue);
      expect(result['relay']!.ownerRepositoryId, 'app');
    });
  });
}

import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/mcp/tools/checkout_reach.dart';
import 'package:karmashala_host/src/mcp/tools/project_folders.dart';
import 'package:karmashala_host/src/mcp/tools/session_checkout_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/worktree_tool_set.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repo_tool_fixture.dart';

/// Sessions without a project: the folder each one gets under a machine's
/// one Scratch project, the rule that lets such a session span any checkout
/// while an ordinary one stays in its project, and the tools an agent attaches
/// and detaches checkouts with.
void main() {
  late RepoToolFixture fixture;

  setUp(() => fixture = RepoToolFixture());
  tearDown(() => fixture.dispose());

  ExecutionEnvironment host() => fixture.reach.host!;

  Session session(String id, String repositoryId) {
    final row = Session(
      id: id,
      repositoryId: repositoryId,
      agentInstallationId: 'a1',
      title: 'Session $id',
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: RepoToolFixture.now,
    );
    SessionDao(fixture.database).insert(row);
    SessionRepositoryDao(
      fixture.database,
    ).link(id, repositoryId, role: SessionRepositoryRole.primary);
    return row;
  }

  group('the folder name', () {
    test('is the day, five words of the hint and the id', () {
      expect(
        scratchFolderName(
          DateTime.utc(2026, 9, 25, 14),
          'Convert these PNGs to WebP, please — all of them',
          'a1b2c3',
        ),
        '2026-09-25-convert-these-pngs-to-webp-a1b2c3',
      );
    });

    test('has no words when there is no hint', () {
      expect(
        scratchFolderName(DateTime.utc(2026, 9, 25), null, 'a1b2c3'),
        '2026-09-25-a1b2c3',
      );
      expect(
        scratchFolderName(DateTime.utc(2026, 9, 25), '!!! ???', 'a1b2c3'),
        '2026-09-25-a1b2c3',
      );
    });
  });

  group('createScratchCheckout', () {
    test(
      'makes a repository under ~/karmashala/scratch and records it',
      () async {
        final checkout = await fixture.folders.createScratchCheckout(
          target: host(),
          hint: 'tidy the downloads folder',
        );

        final root = p.join(fixture.home, 'karmashala', 'scratch');
        expect(p.dirname(checkout.path.path), root);
        expect(
          p.basename(checkout.path.path),
          startsWith('2026-09-27-tidy-the-downloads-folder-'),
        );
        expect(checkout.name, p.basename(checkout.path.path));
        expect(
          Directory(p.join(checkout.path.path, '.git')).existsSync(),
          isTrue,
          reason: 'checkpoints are git trees',
        );

        final project = ProjectDao(
          fixture.database,
        ).getById(checkout.projectId)!;
        expect(project.name, 'Scratch');
        expect(project.isScratch, isTrue);
        expect(project.root.path, root);
      },
    );

    test('a second session joins the one Scratch project', () async {
      final first = await fixture.folders.createScratchCheckout(target: host());
      final second = await fixture.folders.createScratchCheckout(
        target: host(),
      );

      expect(second.projectId, first.projectId);
      expect(second.path, isNot(first.path));
      expect(
        ProjectDao(fixture.database).getAll().where((p) => p.isScratch),
        hasLength(1),
      );
      expect(
        RepositoryDao(fixture.database).getByProject(first.projectId),
        hasLength(2),
      );
    });

    test('the scratch project reads back as such over the wire', () async {
      final checkout = await fixture.folders.createScratchCheckout(
        target: host(),
      );
      final project = ProjectDao(fixture.database).getById(checkout.projectId)!;
      expect(Project.fromJson(project.toJson()).isScratch, isTrue);
      expect(Project.fromJson(project.toJson()), project);
    });
  });

  group('createScratchCheckout in a POSIX environment', () {
    test('spells the folder into the shell script unquoted, inside the '
        'quoted path', () async {
      // `TARGET="$ROOT/'name'"` once put the quotes into the path, which the
      // shell read as an empty one: mkdir: cannot create directory ''.
      final requests = <CommandRequest>[];
      final wsl = ExecutionEnvironment(
        id: 'wsl:arch',
        kind: EnvironmentKind.wsl,
        name: 'arch',
        wslDistribution: 'arch',
        createdAt: RepoToolFixture.now,
      );
      fixture.data.ensureEnvironment(wsl);
      final folders = ProjectFolders(
        fixture.context,
        CheckoutReach(
          fixture.database,
          runners: _Answering((request) {
            requests.add(request);
            return const CommandResult(
              exitCode: 0,
              stdout:
                  '/home/me/karmashala/scratch\n'
                  '/home/me/karmashala/scratch/2026-09-27-tidy-abc123\n',
              stderr: '',
            );
          }),
        ),
        localHome: fixture.home,
        now: () => RepoToolFixture.now,
      );

      final checkout = await folders.createScratchCheckout(
        target: wsl,
        hint: 'tidy',
      );

      // Through stdin, not argv: a WSL distribution re-parses an argument
      // line in the user's shell, which breaks a quoted, multi-line script.
      expect(requests.single.arguments, ['-s']);
      final script = requests.single.stdinText!;
      expect(script, contains('TARGET="\$ROOT/2026-09-27-tidy-'));
      expect(script, isNot(contains("'")));
      expect(
        checkout.path.path,
        '/home/me/karmashala/scratch/2026-09-27-tidy-abc123',
      );
      expect(
        ProjectDao(fixture.database).getById(checkout.projectId)!.root.path,
        '/home/me/karmashala/scratch',
      );
    });
  });

  group('what a session may span', () {
    test('an ordinary session stays within its project', () async {
      final a = fixture.project('a', fixture.repository(fixture.path('a')));
      final b = fixture.project('b', fixture.repository(fixture.path('b')));
      session('s1', a.repositories.single.id);

      expect(
        () => fixture.context.write(
          SessionLinkAdd(
            sessionId: 's1',
            repositoryId: b.repositories.single.id,
          ),
        ),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.message,
            'message',
            contains('same project'),
          ),
        ),
      );
    });

    test('a session without a project may attach any checkout', () async {
      final scratch = await fixture.folders.createScratchCheckout(
        target: host(),
      );
      final b = fixture.project('b', fixture.repository(fixture.path('b')));
      session('s1', scratch.id);

      final links = fixture.context.write(
        SessionLinkAdd(sessionId: 's1', repositoryId: b.repositories.single.id),
      );
      expect(links.map((l) => l.repositoryId), [
        scratch.id,
        b.repositories.single.id,
      ]);
    });

    test('Scratch cannot be deleted while a session runs in it', () async {
      final scratch = await fixture.folders.createScratchCheckout(
        target: host(),
      );
      session('s1', scratch.id);

      expect(
        () => fixture.context.write(ProjectDelete(scratch.projectId)),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.message,
            'message',
            contains('holds 1 session'),
          ),
        ),
      );
      expect(
        ProjectDao(fixture.database).getById(scratch.projectId),
        isNotNull,
      );
    });
  });

  group('session_checkout_attach and _detach', () {
    late SessionCheckoutToolSet tools;

    setUp(() {
      tools = SessionCheckoutToolSet(
        fixture.context,
        worktrees: WorktreeToolSet(
          fixture.context,
          reach: fixture.reach,
          folders: fixture.folders,
          worktrees: fixture.worktrees,
        ),
      );
    });

    Future<({Object? value, String? error})> call(
      String tool,
      Map<String, dynamic> arguments, {
      String? caller,
    }) => RepoToolFixture.outcome(tools.call(tool, arguments, caller));

    test('attaches a checkout to the calling session and lists them', () async {
      final scratch = await fixture.folders.createScratchCheckout(
        target: host(),
      );
      final b = fixture.project('b', fixture.repository(fixture.path('b')));
      session('s1', scratch.id);

      final answer = await call('session_checkout_attach', {
        'repositoryId': b.repositories.single.id,
      }, caller: 's1');

      expect(answer.error, isNull);
      final value = answer.value! as Map<String, Object?>;
      expect(value['sessionId'], 's1');
      expect(value['repositoryId'], b.repositories.single.id);
      expect(value['project'], 'b');
      expect(value['isolation'], contains('shared checkout'));
      expect((value['attached']! as List).map((e) => (e as Map)['role']), [
        'primary',
        'additional',
      ]);
    });

    test('with worktree it makes one and attaches that instead', () async {
      final scratch = await fixture.folders.createScratchCheckout(
        target: host(),
      );
      final b = fixture.project('b', fixture.repository(fixture.path('b')));
      session('s1', scratch.id);

      final answer = await call('session_checkout_attach', {
        'repositoryId': b.repositories.single.id,
        'worktree': {'name': 'feature', 'branch': 'feature/x'},
      }, caller: 's1');

      expect(answer.error, isNull);
      final value = answer.value! as Map<String, Object?>;
      expect(value['repositoryId'], isNot(b.repositories.single.id));
      expect(value['path'], contains('.karmashala-worktrees'));
      expect(value['isolation'], contains('feature/x'));
      expect(
        SessionRepositoryDao(
          fixture.database,
        ).linksFor('s1').map((l) => l.repositoryId),
        contains(value['repositoryId']),
      );
    });

    test(
      'refuses an ordinary session another project, in the server\'s words',
      () async {
        final a = fixture.project('a', fixture.repository(fixture.path('a')));
        final b = fixture.project('b', fixture.repository(fixture.path('b')));
        session('s1', a.repositories.single.id);

        final answer = await call('session_checkout_attach', {
          'repositoryId': b.repositories.single.id,
        }, caller: 's1');

        expect(answer.error, contains('same project'));
      },
    );

    test('detaches an additional checkout but never the primary', () async {
      final scratch = await fixture.folders.createScratchCheckout(
        target: host(),
      );
      final b = fixture.project('b', fixture.repository(fixture.path('b')));
      session('s1', scratch.id);
      await call('session_checkout_attach', {
        'repositoryId': b.repositories.single.id,
      }, caller: 's1');

      final primary = await call('session_checkout_detach', {
        'repositoryId': scratch.id,
      }, caller: 's1');
      expect(primary.error, contains('cannot be detached'));

      final answer = await call('session_checkout_detach', {
        'repositoryId': b.repositories.single.id,
      }, caller: 's1');
      expect(answer.error, isNull);
      expect(
        ((answer.value! as Map)['attached'] as List).map(
          (e) => (e as Map)['repositoryId'],
        ),
        [scratch.id],
      );
    });

    test('without a calling session, sessionId is required', () async {
      final answer = await call('session_checkout_attach', {
        'repositoryId': 'x',
      });
      expect(answer.error, contains('sessionId is required'));
    });
  });
}

/// A runner factory whose every environment answers from one responder.
class _Answering extends CommandRunnerFactory {
  const _Answering(this.responder);

  final CommandResult Function(CommandRequest request) responder;

  @override
  bool get canReachRemote => true;

  @override
  CommandRunner forEnvironment(ExecutionEnvironment environment) =>
      _AnsweringRunner(responder, environment.id);
}

class _AnsweringRunner implements CommandRunner {
  const _AnsweringRunner(this.responder, this.environmentId);

  final CommandResult Function(CommandRequest request) responder;

  @override
  final String environmentId;

  @override
  Future<CommandResult> run(CommandRequest request) async => responder(request);

  @override
  Future<ProcessHandle> start(CommandRequest request) =>
      throw UnsupportedError('not started here');
}

import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_git/git.dart' show GitException, WorktreeSetupReport;
import 'package:karmashala_git/store.dart' show WorktreeSetupDao;
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../automations/daemon_checkout_facts.dart';
import '../domain/session_registry.dart';
import '../pty/pty.dart';

/// The host session id prefix of a worktree's setup or teardown command.
/// Never `karmashala_…`, so none is ever read as a session row's process.
const String kWorktreeSetupSessionPrefix = 'karmashala-setup-';

/// The app's worktree creation, run by the session host for a session a phone
/// starts in a worktree of its own: the same staged creation, the same setup
/// setting and verdict table (recorded through [record], which tells every
/// client) — with a repository's setup command run as a
/// session this host owns (watchable from any client) where the app would
/// open a pane. [environmentOf] widens where it makes them (the agent tools
/// reach WSL from a Windows server, and an SSH box through [runners]); by
/// default only this machine's own environment. A setup command on an SSH box
/// is not run: the server has no session there to run it in, and says so.
WorktreeService daemonWorktrees({
  required AppDatabase database,
  required SessionRegistry registry,
  required DaemonCheckoutFacts facts,
  required String Function() newId,
  required void Function(WorktreeSetupReport report) record,
  WorktreeEnvironmentOf? environmentOf,
  CommandRunnerFactory runners = const CommandRunnerFactory(),
}) {
  final rows = CheckoutRows(database);
  final setups = WorktreeSetupDao(database);
  late final WorktreeSetupService setup;
  setup = WorktreeSetupService(
    runnerFactory: runners,
    lookup: (repo) {
      for (final row in database.query(
        'SELECT id, environment_id, path FROM repositories '
        'WHERE environment_id = ?;',
        [repo.environmentId],
      )) {
        if (!p.equals(row['path']! as String, repo.path)) continue;
        final id = row['id']! as String;
        return (repositoryId: id, setup: setups.get(id));
      }
      return null;
    },
    record: record,
    openPane: (command) {
      if (command.environment.kind == EnvironmentKind.ssh) return null;
      final id = '$kWorktreeSetupSessionPrefix${newId()}';
      final session = registry.open(
        id,
        PtySpawnRequest(
          argv: command.argv,
          workingDirectory: command.worktree.path,
          environment: const {'TERM': 'xterm-256color'},
          columns: 120,
          rows: 40,
        ),
      );
      // Its exit is the verdict; its record is let go once read.
      unawaited(
        session.drained.then((end) async {
          setup.noteExit(id, end.exitCode);
          try {
            await registry.close(id);
          } on Object {
            // Pruned already.
          }
        }),
      );
      return id;
    },
    closePane: (id) => unawaited(
      registry.close(id).then<void>((_) {}, onError: (Object _) {}),
    ),
  );
  return WorktreeService(
    runnerFactory: runners,
    environmentOf:
        environmentOf ??
        (repo) {
          final environment = rows.environment(repo.environmentId);
          if (environment == null || !facts.isHere(environment)) {
            throw GitException(
              'The session host makes worktrees only on this machine, and '
              '${environment?.name ?? repo.environmentId} is not it',
            );
          }
          return environment;
        },
    setup: setup,
  );
}

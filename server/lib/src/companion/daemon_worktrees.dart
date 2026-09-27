import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show hostedRunSessionId;
import 'package:karmashala_git/git.dart' show GitException, WorktreeSetupReport;
import 'package:karmashala_git/store.dart' show WorktreeSetupDao;
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../automations/daemon_checkout_facts.dart';
import '../domain/session_registry.dart';
import '../pty/environment_spawn.dart';

/// The pane id prefix of a worktree's setup or teardown command. Its host
/// session is named as every server-hosted run's is (`hostedRunSessionId`,
/// the terminal's `hostSessionIdFor` rule), so a client opens an attach-only
/// pane on it, and no session row is ever read into it.
const String kWorktreeSetupPanePrefix = 'setup-';

/// The host session a setup pane [paneId] runs in.
String worktreeSetupHostSessionId(String paneId) => hostedRunSessionId(paneId);

/// Worktree creation and removal as the server does them — for a client's
/// `worktrees.create`, an agent's tool and a session a phone starts in a
/// worktree of its own: the staged creation, the setup setting and verdict
/// table (recorded through [record], which tells every client) — with a
/// repository's setup and teardown commands run as sessions this host owns
/// (watchable from any client). A command is run in this machine's own
/// environment, or a WSL distribution of a Windows server (slice 5a); on an
/// SSH box its verdict says no pane could be opened for it. [environmentOf] widens where git runs (WSL from a Windows
/// server, an SSH box through [runners]); by default only this machine's own
/// environment.
WorktreeService daemonWorktrees({
  required AppDatabase database,
  required SessionRegistry registry,
  required DaemonCheckoutFacts facts,
  required String Function() newId,
  required void Function(WorktreeSetupReport report) record,
  WorktreeEnvironmentOf? environmentOf,
  CommandRunnerFactory runners = const CommandRunnerFactory(),
  WorktreeCreations? creations,
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
      // A PTY is spawned here, on this machine: a command for another
      // environment is not run in the wrong place.
      if (!facts.isHere(command.environment)) return null;
      final paneId = '$kWorktreeSetupPanePrefix${newId()}';
      // A WSL checkout's command goes through `wsl.exe` (slice 5a).
      final session = registry.open(
        worktreeSetupHostSessionId(paneId),
        spawnRequestIn(
          command.environment,
          argv: command.argv,
          directory: command.worktree.path,
        ),
      );
      // Its exit is the verdict. Its record is kept — a client opening the
      // pane afterwards is shown what it printed — until the registry's own
      // retention of ended sessions lets it go.
      unawaited(
        session.drained.then((end) => setup.noteExit(paneId, end.exitCode)),
      );
      return paneId;
    },
    closePane: (paneId) => unawaited(
      registry
          .close(worktreeSetupHostSessionId(paneId))
          .then<void>((_) {}, onError: (Object _) {}),
    ),
  );
  return WorktreeService(
    runnerFactory: runners,
    creations: creations,
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

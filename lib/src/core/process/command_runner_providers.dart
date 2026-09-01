import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ssh/application/ssh_providers.dart';
import 'command_runner.dart';
import 'command_runner_factory.dart';
import 'path_translator.dart';
import 'local_command_runner.dart';

/// The command runner for the **Windows host** — used to run host tools such as
/// `wsl.exe` (e.g. for environment discovery). Overridden in tests with a
/// `FakeCommandRunner`.
final hostCommandRunnerProvider = Provider<CommandRunner>(
  (ref) => const LocalCommandRunner(),
);

/// Provides the [PathTranslator] for explicit Windows⇄WSL path translation.
final pathTranslatorProvider = Provider<PathTranslator>(
  (ref) => const PathTranslator(),
);

/// Provides the [CommandRunnerFactory] mapping an environment to a runner.
/// Overridden in tests to hand out a `FakeCommandRunner`.
///
/// The SSH connection pool is read lazily, inside [CommandRunnerFactory], so
/// composing the factory never opens a database or a socket — only actually
/// asking for a remote runner does.
final commandRunnerFactoryProvider = Provider<CommandRunnerFactory>(
  (ref) => CommandRunnerFactory(
    sshConnections: () => ref.read(sshConnectionPoolProvider),
  ),
);

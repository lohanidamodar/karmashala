import 'package:riverpod/riverpod.dart';

import '../../features/ssh/application/ssh_providers.dart';
import '../../features/ssh/data/ssh_command_runner.dart';
import 'package:agent_cli/process.dart';

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
/// [SshCommandRunnerFactory] is the app's own subclass: `agent_cli` places the
/// local and WSL environments and hands anything else to `unsupported`, which
/// is where this app's SSH transport lives.
///
/// The SSH connection pool is read lazily, inside the factory, so composing it
/// never opens a database or a socket — only actually asking for a remote
/// runner does.
final commandRunnerFactoryProvider = Provider<CommandRunnerFactory>(
  (ref) => SshCommandRunnerFactory(
    sshConnections: () => ref.read(sshConnectionPoolProvider),
  ),
);

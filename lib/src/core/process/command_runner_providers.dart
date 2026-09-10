import 'package:riverpod/riverpod.dart';

import '../../features/ssh/application/ssh_providers.dart';
import 'package:karmashala_ssh/runner.dart';
import 'package:agent_cli/process.dart';

/// The command runner for the **Windows host**, for host tools such as
/// `wsl.exe`. Overridden in tests with a `FakeCommandRunner`.
final hostCommandRunnerProvider = Provider<CommandRunner>(
  (ref) => const LocalCommandRunner(),
);

/// Provides the [PathTranslator] for explicit Windows⇄WSL path translation.
final pathTranslatorProvider = Provider<PathTranslator>(
  (ref) => const PathTranslator(),
);

/// Provides the [CommandRunnerFactory] mapping an environment to a runner.
/// The SSH pool is read lazily inside it, so composing opens no socket.
final commandRunnerFactoryProvider = Provider<CommandRunnerFactory>(
  (ref) => SshCommandRunnerFactory(
    sshConnections: () => ref.read(sshConnectionPoolProvider),
  ),
);

import 'package:riverpod/riverpod.dart';

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

/// Provides the [CommandRunnerFactory] mapping an environment to a runner:
/// this machine and its WSL distributions. An SSH box is the server's alone
/// (slice 5d) — this factory refuses it in words, and the app dials nothing.
final commandRunnerFactoryProvider = Provider<CommandRunnerFactory>(
  (ref) => const CommandRunnerFactory(),
);

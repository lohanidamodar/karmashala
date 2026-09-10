import 'agent_pane_launch.dart';
import 'terminal_profile.dart';

/// The kind of shell a command is being handed to — the *destination*, not the
/// platform the app happens to run on: `Platform.isWindows` says where we are,
/// [ShellContextKind] says where the command is going.
enum ShellContextKind {
  /// A Windows executable started directly from a Windows host.
  windowsNative,

  /// PowerShell on a Windows host.
  powerShell,

  /// `cmd.exe` on a Windows host.
  commandPrompt,

  /// A WSL distribution reached from a Windows host — the only kind that needs
  /// `wsl.exe` in front of the command.
  wsl,

  /// A POSIX shell we are **already inside** — the app on Linux/macOS, or the
  /// very WSL distribution the command targets. Nothing to cross or wrap.
  posix,
}

/// Where a command will actually run, and therefore how it has to be spelled.
/// Every builder takes one of these instead of a bare `Platform.isWindows`: the
/// boolean answers "where is the app?" when the question is "what parses it?".
class LaunchContext {
  const LaunchContext._(this.kind, {this.wslDistribution, this.posixShell});

  /// A Windows executable run from a Windows host.
  const LaunchContext.windowsNative() : this._(ShellContextKind.windowsNative);

  /// PowerShell on a Windows host.
  const LaunchContext.powerShell() : this._(ShellContextKind.powerShell);

  /// `cmd.exe` on a Windows host.
  const LaunchContext.commandPrompt() : this._(ShellContextKind.commandPrompt);

  /// A WSL distribution reached from a Windows host via `wsl.exe`.
  const LaunchContext.wsl(String distribution)
    : this._(ShellContextKind.wsl, wslDistribution: distribution);

  /// A POSIX shell we are already running in. [shell] is the login shell to
  /// open when the *shell itself* is what is being launched.
  const LaunchContext.posix({String? shell})
    : this._(ShellContextKind.posix, posixShell: shell);

  /// Already running **inside** [distribution]. Distinct from
  /// [LaunchContext.wsl] in exactly the way that matters: the distribution is
  /// known, and `wsl.exe` must not be used to reach it.
  const LaunchContext.insideWsl(String distribution, {String? shell})
    : this._(
        ShellContextKind.posix,
        wslDistribution: distribution,
        posixShell: shell,
      );

  final ShellContextKind kind;

  /// The distribution this context names — the one to cross into for
  /// [ShellContextKind.wsl], or the one we are already inside for
  /// [LaunchContext.insideWsl].
  final String? wslDistribution;

  /// The login shell for a POSIX context, when one is known.
  final String? posixShell;

  /// Whether the host process can reach `wsl.exe`, `cmd.exe` and
  /// `powershell.exe` at all.
  bool get isWindowsHost => kind != ShellContextKind.posix;

  /// Whether a command handed to this context needs a wrapper in front of it.
  bool get needsWrapper => kind != ShellContextKind.posix;

  /// The context an agent pane's command is going into. Off Windows we are
  /// already inside a POSIX shell, so no `wsl.exe` wrapper is available.
  factory LaunchContext.forAgent(
    AgentPaneLaunch launch, {
    required bool hostIsWindows,
  }) {
    final distro = launch.wslDistribution;
    final hasDistro = distro != null && distro.isNotEmpty;
    if (!hostIsWindows) {
      return hasDistro
          ? LaunchContext.insideWsl(distro)
          : const LaunchContext.posix();
    }
    return hasDistro
        ? LaunchContext.wsl(distro)
        : const LaunchContext.windowsNative();
  }

  /// The context a shell [profile] opens into. On a POSIX host the profiles are
  /// meaningless — `powershell.exe`/`cmd.exe`/`wsl.exe` do not exist — so every
  /// one of them resolves to the login shell we are already in.
  factory LaunchContext.forProfile(
    TerminalProfile profile, {
    required bool hostIsWindows,
    String? posixShell,
  }) {
    if (profile.shell == TerminalShell.ssh) {
      throw ArgumentError.value(
        profile.id,
        'profile',
        'SSH profiles must be launched by the SSH terminal backend',
      );
    }
    if (!hostIsWindows) {
      // The profile's own shell wins over the ambient `$SHELL`: picking zsh in
      // settings has to actually open zsh. Off Windows every profile used to
      // collapse to `$SHELL`, so the picker was inert.
      final shell = profile.posixShellPath ?? posixShell;
      final distro = profile.wslDistribution;
      return distro == null || distro.isEmpty
          ? LaunchContext.posix(shell: shell)
          : LaunchContext.insideWsl(distro, shell: shell);
    }
    return switch (profile.shell) {
      TerminalShell.powerShell => const LaunchContext.powerShell(),
      TerminalShell.commandPrompt => const LaunchContext.commandPrompt(),
      TerminalShell.wsl => LaunchContext.wsl(profile.wslDistribution ?? ''),
      // Only reachable if a POSIX profile were somehow stored on a Windows
      // host. Its shell path means nothing here, so the host default is the
      // honest answer.
      TerminalShell.posix => const LaunchContext.powerShell(),
      TerminalShell.ssh => throw StateError('handled above'),
    };
  }

  /// The context a command runs in when its environment is [wslDistribution]
  /// on a Windows host — the external-terminal and copy-command paths, where
  /// the only question is whether the line has to cross into a distribution.
  factory LaunchContext.forEnvironment(
    String? wslDistribution, {
    bool hostIsWindows = true,
  }) => LaunchContext.forAgent(
    AgentPaneLaunch(
      agentId: '',
      executable: '',
      wslDistribution: wslDistribution,
    ),
    hostIsWindows: hostIsWindows,
  );

  @override
  bool operator ==(Object other) =>
      other is LaunchContext &&
      other.kind == kind &&
      other.wslDistribution == wslDistribution &&
      other.posixShell == posixShell;

  @override
  int get hashCode => Object.hash(kind, wslDistribution, posixShell);

  @override
  String toString() =>
      'LaunchContext(${kind.name}'
      '${wslDistribution == null ? '' : ', $wslDistribution'})';
}

/// A command in the words of the environment it will run in, before any
/// wrapper. Wrapping consumes one and returns something with no route back.
class ShellCommand {
  const ShellCommand({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
  });

  final String executable;
  final List<String> arguments;

  /// The directory the command starts in, expressed in its own environment.
  final String? workingDirectory;

  /// Variables the command needs beyond the inherited environment. Crossing
  /// into WSL these need naming in `WSLENV` as well, which the wrapper does.
  final Map<String, String> environment;

  /// The executable and its arguments as one list.
  List<String> get parts => [executable, ...arguments];
}

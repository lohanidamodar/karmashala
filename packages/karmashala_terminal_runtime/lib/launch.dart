/// How a command is spelled for where it runs: the argv builders and quoting
/// rules. The server builds every pane's launch with them on its own OS since
/// slice 5a (`karmashala_launch`); a client keeps them for the external
/// terminal it opens and the command it copies. The profiles and shell
/// scripts are `karmashala_terminal_core`'s `profiles.dart` and
/// `shell_integration.dart`.
library;

export 'package:karmashala_launch/karmashala_launch.dart'
    show
        PtyLaunch,
        TerminalLaunch,
        agentPtyLaunchFor,
        encodedPosixShellCommand,
        posixShellCommand,
        powerShellInvocation,
        powerShellLiteral,
        ptyChildEnvironment,
        ptyLaunchFor,
        quotePosixShellArgument,
        quotePowerShellArgument,
        quoteWindowsCommandArgument,
        shellIntegrationApplies,
        terminalLaunchFor,
        throughCommandPrompt,
        withWslEnv,
        wrapForExternalTerminal,
        wrapForPty;

/// What a terminal launches: the shell or agent behind a pane, and the
/// destination its command is quoted for. Pure Dart since slice 5a
/// (`karmashala_launch`), re-exported here for the client's vocabulary.
library;

export 'package:karmashala_launch/karmashala_launch.dart'
    show
        AgentPaneLaunch,
        LaunchContext,
        ShellCommand,
        ShellContextKind,
        TerminalProfile,
        TerminalShell,
        kSessionIdEnvironmentVariable,
        kSessionPortBaseEnvironmentVariable,
        kSessionPortBaseFloor,
        kSessionPortBaseSlots,
        kSessionPortsPerSession,
        resolveTerminalProfile,
        sessionPortBase,
        terminalProfileFromId,
        terminalProfilesFor;

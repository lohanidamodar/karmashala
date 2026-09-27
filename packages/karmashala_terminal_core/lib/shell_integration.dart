/// What the shell tells the terminal, and the scripts that make it: OSC 133
/// command blocks, OSC 7 working directories, and the OSC fan-out.
library;

export 'src/command_blocks.dart';
export 'src/osc_router.dart';
export 'package:karmashala_launch/karmashala_launch.dart'
    show
        bashIntegrationRcFile,
        powerShellIntegrationScript,
        shellSupportsIntegration,
        workingDirectoryFromOsc,
        wslIntegrationBootstrap,
        zshIntegrationZprofile,
        zshIntegrationZshenv,
        zshIntegrationZshrc;

/// The running terminals themselves: a local ConPTY or forkpty, a pane on a
/// deployed session host, and a shell on an SSH channel — behind one
/// [TerminalInstance] the app drives without knowing which it holds. With them
/// the buffer they paint into, whose columns settle across a drag, and the
/// typer that leaves a command at a prompt without running it.
library;

export 'src/host_terminal_instance.dart';
export 'src/pane_terminal.dart';
export 'src/prompt_typer.dart';
export 'src/terminal_instance.dart';

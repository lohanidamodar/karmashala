/// Reading a screen back. The grid text an agent's last lines are taken from,
/// the recorder that turns OSC 133 boundaries into command blocks, and the
/// watch that waits for one command to finish and names its exit code.
library;

export 'src/command_block_recorder.dart';
export 'src/command_run_watch.dart';
export 'src/terminal_grid_text.dart';

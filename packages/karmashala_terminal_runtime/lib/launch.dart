/// Starting the process behind a pane and ending it again: the command line a
/// profile becomes — argv, environment and working directory, with every
/// user-supplied byte kept off it — and the graceful-then-forced shutdown that
/// tears the process down without destroying its work.
library;

export 'src/process_shutdown.dart';
export 'src/pty_launch.dart';

/// The applications the operating system already lists, read rather than
/// guessed: the Start Menu on Windows, `/Applications` on macOS, `.desktop`
/// entries on Linux. The model and its parsers only; finding them on disk is
/// the caller's.
library;

export 'src/apps/installed_application.dart';

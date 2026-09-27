/// The whole package. Prefer one of the three narrow entries — `connection`,
/// `runner`, `files` — so an import says what it reaches for. Deploying the
/// server on a box is `karmashala_ssh_host`.
library;

export 'connection.dart';
export 'files.dart';
export 'runner.dart';

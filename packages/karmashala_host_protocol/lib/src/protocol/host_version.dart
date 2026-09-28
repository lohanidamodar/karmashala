/// The host's own version: the release it ships in, the app's version without
/// its build number (`app/pubspec.yaml`). A machine can still run a host older
/// than the app that deployed it — that is what this tells apart.
///
/// Kept in step by hand, because `dart build cli` takes no `--define`; the
/// server's `host_version_test.dart` fails when the app's version moves
/// without it. It stayed `0.1.0` through every release until 1.26.3.
const String kHostVersion = '1.26.3';

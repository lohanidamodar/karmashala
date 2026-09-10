/// Doubles for testing against this package's types. They sit in `lib/` because
/// the app's suites need them too and a package cannot import another's test
/// tree; nothing in `lib/src` imports this, so it is tree-shaken out.
library;

export 'src/testing/fake_path_probe.dart';

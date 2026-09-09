/// Doubles and readers for testing against this package's types.
///
/// They live in `lib/` rather than a `test/support/` folder because both this
/// package's suites and the app's need them, and a package cannot import
/// another package's test tree. `FakePathProbe` implements `PathProbe` and
/// `readMp4Track` reads back what `media.dart` writes, so each is coupled to an
/// API this package owns and has nowhere better to live.
///
/// Nothing under `lib/src/{logging,util,paths,media}` imports this library, so
/// it is tree-shaken out of the app.
library;

export 'src/testing/fake_path_probe.dart';
export 'src/testing/mp4_reader.dart';

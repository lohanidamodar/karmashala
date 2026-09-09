/// Doubles for testing against this package's types.
///
/// `FakePathProbe` lives in `lib/` rather than a `test/support/` folder because
/// both this package's suites and the app's need it, and a package cannot
/// import another package's test tree. It implements `PathProbe`, so it is
/// coupled to an API this package owns and has nowhere better to live.
/// (`readMp4Track` left with the media layer, in `karmashala_media`.)
///
/// Nothing under `lib/src/{logging,util,paths}` imports this library, so it is
/// tree-shaken out of the app.
library;

export 'src/testing/fake_path_probe.dart';

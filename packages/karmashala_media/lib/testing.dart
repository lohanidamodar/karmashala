/// Readers for testing against this package's types.
///
/// `readMp4Track` lives in `lib/` rather than `test/support/` because both this
/// package's suites and the app's need it, and a package cannot import another
/// package's test tree. It reads back what `media.dart` writes, so it is
/// coupled to an API this package owns and has nowhere better to live.
///
/// Nothing under `lib/src/media` imports this library, so it is tree-shaken out
/// of the app.
library;

export 'src/testing/mp4_reader.dart';

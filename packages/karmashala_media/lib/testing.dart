/// Readers for testing against this package's types. In `lib/` because the
/// app's suites need them too and no package can import another's test tree;
/// nothing under `lib/src` imports this, so it tree-shakes out of the app.
library;

export 'src/testing/mp4_reader.dart';

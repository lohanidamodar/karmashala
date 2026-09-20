/// The kinds of app project a checkout can hold — what the toolchain says a
/// directory is, not `features/projects`. Closed by code: a parse is not data.
enum ProjectKind {
  flutter('Flutter'),
  reactNative('React Native'),
  nativeAndroid('Native Android'),
  nativeIos('Native iOS');

  const ProjectKind(this.label);

  /// What a person sees. Not the enum name.
  final String label;
}

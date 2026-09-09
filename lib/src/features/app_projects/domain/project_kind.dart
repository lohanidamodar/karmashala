/// The kinds of app project a checkout can hold.
///
/// **Not `features/projects`.** That is the workspace's own grouping of
/// repositories, which a person names. This is what the *toolchain* says a
/// directory is: which markers it carries, and therefore which commands build
/// it. The two words collide and the concepts do not.
///
/// Closed by code for the reason [AgentKind] is: the marker reading for a kind
/// is a hand-written parse, and a parse cannot be data. Everything *after*
/// detection — the build command, where the artifact lands, how the
/// application id is read — is data, and lives on `ProjectDescriptor`.
///
/// A kind with no descriptor is legal and gets detection and nothing else.
enum ProjectKind {
  flutter('Flutter'),
  reactNative('React Native'),
  nativeAndroid('Native Android'),
  nativeIos('Native iOS');

  const ProjectKind(this.label);

  /// What a person sees. Not the enum name.
  final String label;
}

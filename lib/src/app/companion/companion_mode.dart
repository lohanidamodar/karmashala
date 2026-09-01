/// Which app this binary is: the desktop, or the mobile companion.
///
/// Companion mode is chosen at **build time** —
/// `--dart-define=KARMASHALA_MODE=companion` — and read here and nowhere
/// else. The const lets the compiler drop the desktop bootstrap (PTYs,
/// discovery, control server, tray, window chrome) from a companion build
/// entirely, and vice versa.
class CompanionMode {
  const CompanionMode._();

  static const String _define = String.fromEnvironment('KARMASHALA_MODE');

  /// The rule, separately callable so a test can pin what the define means.
  static bool isCompanion(String mode) => mode == 'companion';

  /// Whether this build is the companion. Must stay a `const` expression —
  /// see the library comment.
  static const bool enabled = _define == 'companion';
}

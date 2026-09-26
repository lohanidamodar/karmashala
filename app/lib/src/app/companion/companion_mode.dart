/// Which app this binary is. Chosen at **build time** —
/// `--dart-define=KARMASHALA_MODE=companion` — so the compiler drops the other.
class CompanionMode {
  const CompanionMode._();

  static const String _define = String.fromEnvironment('KARMASHALA_MODE');

  /// The rule, separately callable so a test can pin what the define means.
  static bool isCompanion(String mode) => mode == 'companion';

  /// Whether this build is the companion. Must stay a `const` expression —
  /// see the library comment.
  static const bool enabled = _define == 'companion';
}

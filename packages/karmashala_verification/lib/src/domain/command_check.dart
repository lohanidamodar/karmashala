import 'package:karmashala_core/verdicts.dart';

/// One gate Karmashala ran itself: the command, what it exited with, and what
/// it printed — or why it never ran.
class CommandCheck {
  const CommandCheck({
    required this.name,
    required this.command,
    this.exitCode,
    this.output = '',
    this.refusal,
  });

  final String name;
  final List<String> command;
  final int? exitCode;
  final String output;

  /// Why it never ran, or null when it did.
  final String? refusal;

  /// The verdict this one check earns. A check that never ran, or whose exit
  /// nobody observed, is inconclusive — never a pass (§19).
  VerificationVerdict get verdict => refusal != null || exitCode == null
      ? VerificationVerdict.inconclusive
      : exitCode == 0
      ? VerificationVerdict.pass
      : VerificationVerdict.fail;
}

/// The worst of [verdicts] — fail, then inconclusive, then pass — so the newest
/// verdict of a batch cannot be the last check's pass on top of an earlier
/// failure. An empty batch checked nothing and is inconclusive.
VerificationVerdict worstVerdict(Iterable<VerificationVerdict> verdicts) {
  final all = verdicts.toList();
  if (all.contains(VerificationVerdict.fail)) return VerificationVerdict.fail;
  if (all.isEmpty || all.contains(VerificationVerdict.inconclusive)) {
    return VerificationVerdict.inconclusive;
  }
  return VerificationVerdict.pass;
}

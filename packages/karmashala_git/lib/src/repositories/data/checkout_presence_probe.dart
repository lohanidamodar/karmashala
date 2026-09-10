import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';

/// What could be established about a recorded directory.
///
/// Three states, not two: a `bool` forces "I could not check" to be spelled as
/// one of the answers, and `false` then retires a checkout because a WSL distro
/// happened to be stopped.
enum CheckoutPresence {
  /// The directory was found. Nothing to decide.
  present,

  /// The directory was looked for, on a filesystem that answered, and is not
  /// there. This is the only value that is evidence of a deletion.
  absent,

  /// No answer: an environment with no translation into a reachable path, a
  /// host that is down, a mount that is not mounted, or a call that threw.
  /// Never treated as absence.
  unknown,
}

/// Asks whether a recorded checkout's directory is still on disk.
///
/// Deliberately separate from [RepositoryDiscoveryService]: a scan reports what
/// it *found*, and finding nothing at a path has not established it is gone.
abstract interface class CheckoutPresenceProbe {
  /// Whether [directory] — which belongs to [environment] — is still there,
  /// checked from the Windows host [windows].
  Future<CheckoutPresence> presenceOf(
    EnvironmentPath directory, {
    required ExecutionEnvironment environment,
    required ExecutionEnvironment windows,
  });
}

/// How long one presence question may take before it answers `unknown`.
///
/// Generous enough for a live 9p round trip, short enough that a project full
/// of checkouts in a stopped distribution does not stall a rescan.
const Duration presenceProbeDeadline = Duration(seconds: 2);

/// [CheckoutPresenceProbe] over the local `dart:io` filesystem, reaching other
/// environments through the same [PathTranslator] the app scans with.
///
/// **It cannot tell a stopped distro from a deleted folder**: a WSL path becomes
/// `\\wsl.localhost\<distro>\…` and Windows answers "no such directory" for both,
/// with no error to catch. `CheckoutRetirementService` carries the guard.
class LocalCheckoutPresenceProbe implements CheckoutPresenceProbe {
  const LocalCheckoutPresenceProbe({this.translator = const PathTranslator()});

  final PathTranslator translator;

  @override
  Future<CheckoutPresence> presenceOf(
    EnvironmentPath directory, {
    required ExecutionEnvironment environment,
    required ExecutionEnvironment windows,
  }) async {
    // The honest answer to a question we were not given enough to ask is
    // "unknown", not a check against the wrong filesystem.
    if (directory.environmentId != environment.id) {
      return CheckoutPresence.unknown;
    }

    final String hostPath;
    try {
      hostPath = environment.id == windows.id
          ? directory.path
          : translator
                .translate(directory, from: environment, to: windows)
                .path;
    } on Object {
      // No mapping into the host namespace — an SSH host, or a distro whose name
      // was never recorded. A path we cannot write down is one we cannot check.
      return CheckoutPresence.unknown;
    }

    try {
      // Bounded, because Windows blocks for a long time on a `\\wsl.localhost`
      // UNC when the distribution is not running — once per checkout. A question
      // not answered in time is `unknown`, which never retires anything.
      final exists = await Directory(
        hostPath,
      ).exists().timeout(presenceProbeDeadline);
      return exists ? CheckoutPresence.present : CheckoutPresence.absent;
    } on Object {
      return CheckoutPresence.unknown;
    }
  }
}

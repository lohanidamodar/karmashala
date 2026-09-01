import 'dart:async';
import 'dart:io';

import '../../../core/process/path_translator.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';

/// What could be established about a recorded directory.
///
/// Three states, not two, and that is the whole point of the type. A `bool`
/// forces "I could not check" to be spelled as one of the answers, and either
/// spelling is a lie that costs something: `false` retires a checkout because a
/// WSL distro happened to be stopped, `true` retires nothing ever. The caller
/// has to say which risk it is taking, so it has to see the third state.
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
/// A seam, in the same spirit as `sessionDirectoryPresentProvider`: production
/// touches the filesystem, tests answer from a table. Deliberately separate
/// from [RepositoryDiscoveryService] — a scan reports what it *found*, and a
/// scan that found nothing at a path has not established that the path is gone.
abstract interface class CheckoutPresenceProbe {
  /// Whether [directory] — which belongs to [environment] — is still there,
  /// checked from the Windows host [windows].
  Future<CheckoutPresence> presenceOf(
    EnvironmentPath directory, {
    required ExecutionEnvironment environment,
    required ExecutionEnvironment windows,
  });
}

/// [CheckoutPresenceProbe] backed by the local `dart:io` filesystem, reaching
/// non-Windows environments through the same [PathTranslator] the rest of the
/// app uses to scan them.
///
/// **It cannot tell a stopped distro from a deleted folder.** A WSL path
/// resolves to `\\wsl.localhost\<distro>\…`, and Windows answers "no such
/// directory" both when the folder was removed and when WSL is not running at
/// all — there is no error to catch, just a `false`. Nothing here can fix that,
/// so the guard lives one level up: `CheckoutRetirementService` refuses to
/// retire anything unless the project root itself answered [present], which is
/// the one path we know was there when the scan started.
/// How long one presence question may take before it answers `unknown`.
///
/// Generous enough for a live 9p round trip, short enough that a project full
/// of checkouts in a stopped distribution does not stall a rescan.
const Duration presenceProbeDeadline = Duration(seconds: 2);

class LocalCheckoutPresenceProbe implements CheckoutPresenceProbe {
  const LocalCheckoutPresenceProbe({this.translator = const PathTranslator()});

  final PathTranslator translator;

  @override
  Future<CheckoutPresence> presenceOf(
    EnvironmentPath directory, {
    required ExecutionEnvironment environment,
    required ExecutionEnvironment windows,
  }) async {
    // A path handed to us with the wrong environment is a caller bug, and the
    // honest answer to a question we were not given enough to ask is "unknown"
    // rather than a check against the wrong filesystem.
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
      // No mapping into the host namespace — an SSH host, or a distro whose
      // name was never recorded. A path we cannot write down is a path we
      // cannot check.
      return CheckoutPresence.unknown;
    }

    try {
      // Bounded, because this question can hang. A WSL path becomes
      // `\\wsl.localhost\<distro>\…`, and Windows blocks on that UNC for a
      // long time when the distribution is not running — long enough to stall
      // the rescan that called us, once per checkout. A question we could not
      // answer in time is `unknown`, which never retires anything, so the
      // slow case costs a delay and never a deletion.
      final exists = await Directory(
        hostPath,
      ).exists().timeout(presenceProbeDeadline);
      return exists ? CheckoutPresence.present : CheckoutPresence.absent;
    } on Object {
      return CheckoutPresence.unknown;
    }
  }
}

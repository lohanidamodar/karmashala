// Copied verbatim from packages/karmashala_core/lib/src/paths/path_probe.dart; see PACKAGE_SPLIT.md on consolidation.
import 'dart:io';

import 'package:path/path.dart' as p;

/// What a check of one executable path established.
///
/// Four values because "there is nothing there" and "I could not finish
/// looking" need opposite responses — the first means install it, the second
/// means the file may be perfectly fine and the *route* to it is broken.
/// Collapsing them is the §19 mistake: a reading that could not be taken must
/// not present itself as a reading of zero.
enum ExecutableReachability {
  /// The file opened.
  usable,

  /// The whole route was answerable and there is nothing at the end of it.
  missing,

  /// The file did not open and the route could not be established.
  ///
  /// On Windows this is a chain of junctions the OS declines to follow — *"the
  /// path cannot be traversed because it contains an untrusted mount point"*,
  /// errno 448 — which is how Codex's self-update left `codex.exe` on 0.153.4:
  /// the file runs perfectly at its versioned location and is unreachable
  /// through the stable path the app had stored.
  unreachable,

  /// Nothing was established, because the path is not on this host's
  /// filesystem. A WSL or SSH installation's path is spelled for *its* disk,
  /// so no stat of ours is evidence about it either way.
  unchecked,
}

/// The filesystem questions path repair asks.
///
/// A seam rather than direct `dart:io` calls so a test can describe a disk —
/// junction chains and outright refusals included — instead of depending on
/// whatever happens to be installed on the machine running the suite.
abstract interface class PathProbe {
  /// Whether a file is at [path]; `null` when the OS refused to answer.
  ///
  /// **`false` is not proof of absence on Windows.** Measured 2026-09-07 on the
  /// owner's machine: for a path behind a junction chain Windows will not
  /// traverse, `File.existsSync` answers a flat `false` — it is
  /// `Directory.existsSync` and `Link.existsSync` that raise errno 448, and
  /// `lengthSync` that names the reason. So the exception is not a reliable
  /// discriminator and [readExecutable] does not use it as one; the `null` here
  /// is for the refusals that *are* raised, and the reparse walk is what
  /// actually tells "gone" from "unreachable" apart.
  bool? fileExists(String path);

  /// Whether [path] is itself a reparse point, without following it.
  bool isLink(String path);

  /// Where the reparse point at [path] leads, or `null` if it is not one or
  /// cannot be read. A relative target is returned as written.
  String? linkTarget(String path);
}

/// [PathProbe] against the host's own filesystem.
class LocalPathProbe implements PathProbe {
  const LocalPathProbe();

  @override
  bool? fileExists(String path) {
    try {
      return File(path).existsSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  bool isLink(String path) {
    try {
      return FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link;
    } on FileSystemException {
      return false;
    }
  }

  @override
  String? linkTarget(String path) {
    try {
      return Link(path).targetSync();
    } on FileSystemException {
      return null;
    }
  }
}

/// One executable path, as the filesystem answered — and where the executable
/// actually is when the stored path cannot reach it.
class ExecutableReading {
  const ExecutableReading({
    required this.path,
    required this.reachability,
    this.resolved,
  });

  /// The reading for a path on somebody else's filesystem: nothing observed,
  /// and nothing claimed.
  const ExecutableReading.unchecked(this.path)
    : reachability = ExecutableReachability.unchecked,
      resolved = null;

  /// The path that was checked.
  final String path;

  final ExecutableReachability reachability;

  /// A usable spelling of the same executable, reached by following the reparse
  /// points on [path].
  ///
  /// Null when there is none — including when [path] itself is [usable], which
  /// needs no substitute. Non-null is the repairable case: the executable was
  /// found and only the recorded route to it is wrong.
  final String? resolved;

  bool get isUsable => reachability == ExecutableReachability.usable;

  /// Whether a repair could put this row right, i.e. there is somewhere usable
  /// to move it to.
  bool get isRepairable => resolved != null;
}

/// How [path] answered, according to [probe].
///
/// **The reparse walk is the discriminator, not an exception.** A path behind a
/// junction Windows will not traverse answers `existsSync` with the same `false`
/// an uninstalled CLI does, so absence has to be established by *completing the
/// route*: a path whose links all read and lead nowhere is [missing], and one
/// whose route could not be completed at all is [unreachable].
///
/// [context] is the path spelling to walk in — injected so a test can walk
/// Windows paths on a POSIX host and the reverse.
ExecutableReading readExecutable(
  String path,
  PathProbe probe, {
  p.Context? context,
}) {
  final direct = probe.fileExists(path);
  if (direct == true) {
    return ExecutableReading(
      path: path,
      reachability: ExecutableReachability.usable,
    );
  }

  final resolved = resolveReparsePoints(path, probe, context: context);
  if (resolved != null && resolved != path) {
    final behind = probe.fileExists(resolved);
    if (behind == true) {
      // Installed, and only the recorded route to it is wrong.
      return ExecutableReading(
        path: path,
        reachability: ExecutableReachability.unreachable,
        resolved: resolved,
      );
    }
    // The links all read and led nowhere: the route was completed, and the
    // answer at the end of it is that the file is gone.
    if (behind == false && direct == false) {
      return ExecutableReading(
        path: path,
        reachability: ExecutableReachability.missing,
      );
    }
  }

  return ExecutableReading(
    path: path,
    // `resolved == null` is a chain that could not be walked — an unreadable
    // junction or a cycle. `direct == null` is the OS declining outright.
    // Either way nothing was established, so nothing is claimed.
    reachability: (resolved == null || direct == null)
        ? ExecutableReachability.unreachable
        : ExecutableReachability.missing,
  );
}

/// [path] with every reparse point on the way to it replaced by its target, or
/// `null` when the chain cannot be followed.
///
/// **Why this is not `resolveSymbolicLinksSync`.** That call, and every other
/// whole-path operation, throws on the junction chain Codex's updater installs
/// — the OS refuses the traversal, so nothing that has to traverse can answer.
/// What still works is asking about **one component at a time**: `typeSync(…,
/// followLinks: false)` reports the junction as a link and `Link.targetSync()`
/// reads its target, both of them on the junction itself rather than on
/// anything behind it. Measured on the owner's machine, this walks
///
/// ```txt
/// …\OpenAI\Codex\bin\codex.exe
///   -> …\.codex\packages\standalone\current\bin\codex.exe
///   -> …\releases\0.153.4-x86_64-pc-windows-msvc\bin\codex.exe
/// ```
///
/// in two hops with no subprocess and no PowerShell, and the result runs.
///
/// It is general on purpose. Nothing here knows the word "codex": the next tool
/// to install itself behind a versioned junction gets the same treatment, and
/// a candidate-path glob of one vendor's layout would not have covered it.
///
/// [maxHops] bounds a cycle: a link that leads back to itself returns `null`
/// rather than spinning.
String? resolveReparsePoints(
  String path,
  PathProbe probe, {
  p.Context? context,
  int maxHops = 32,
}) {
  final ctx = context ?? p.context;
  var current = path;
  for (var hop = 0; hop < maxHops; hop++) {
    final step = _followFirstLink(current, probe, ctx);
    if (!step.redirected) return current; // Nothing left to follow.
    if (step.path == null) return null; // A link we cannot read.
    current = step.path!;
  }
  return null; // Too many hops: the chain leads back into itself.
}

/// [path] with its first reparse-point component substituted.
///
/// `redirected: false` means the path holds no reparse point; `redirected: true`
/// with a null `path` means it holds one that cannot be read. The two must not
/// collapse — the first is a finished answer and the second is a dead end, and
/// returning the unresolved path for a dead end is a lie a caller would store.
({bool redirected, String? path}) _followFirstLink(
  String path,
  PathProbe probe,
  p.Context ctx,
) {
  final parts = ctx.split(path);
  // From 1: the root itself is never a reparse point, and asking about `C:\`
  // costs a syscall per hop for an answer that cannot change.
  for (var i = 1; i < parts.length; i++) {
    final prefix = ctx.joinAll(parts.sublist(0, i + 1));
    if (!probe.isLink(prefix)) continue;
    final target = probe.linkTarget(prefix);
    if (target == null) return (redirected: true, path: null);
    final absolute = ctx.isAbsolute(target)
        ? target
        : ctx.normalize(ctx.join(ctx.dirname(prefix), target));
    return (
      redirected: true,
      path: ctx.joinAll([absolute, ...parts.sublist(i + 1)]),
    );
  }
  return (redirected: false, path: null);
}

/// The traversable spelling of [path]: itself when it is already usable,
/// otherwise the reparse-resolved path when *that* is usable, otherwise `null`.
///
/// The order matters. A path that works is left exactly as stored — resolving
/// an ordinary install would replace a stable path with whatever it happens to
/// point at today for no benefit. Only a path that cannot be reached is worth
/// trading for a version-pinned one, and that trade is what the startup check
/// exists to make again after the next update moves it.
String? traversablePath(String path, PathProbe probe, {p.Context? context}) {
  final reading = readExecutable(path, probe, context: context);
  return reading.isUsable ? reading.path : reading.resolved;
}

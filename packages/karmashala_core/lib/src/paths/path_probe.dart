import 'dart:io';

import 'package:path/path.dart' as p;

/// What a check of one executable path established. "Nothing is there" and "I
/// could not finish looking" are separate values because they need opposite
/// responses (CLAUDE.md §20).
enum ExecutableReachability {
  /// The file opened.
  usable,

  /// The whole route was answerable and there is nothing at the end of it.
  missing,

  /// The file did not open and the route could not be established — on Windows,
  /// a junction chain the OS declines to follow (errno 448).
  unreachable,

  /// Not on this host's filesystem: a WSL or SSH path is spelled for *its* disk,
  /// so no stat of ours is evidence either way.
  unchecked,
}

/// The filesystem questions path repair asks, as a seam so a test can describe a
/// disk — junction chains and refusals included — instead of the real one.
abstract interface class PathProbe {
  /// Whether a file is at [path]; `null` when the OS refused to answer.
  ///
  /// **`false` is not proof of absence on Windows**: behind a junction chain it
  /// cannot traverse, `File.existsSync` answers a flat `false` rather than
  /// throwing, so the exception is not a discriminator (CLAUDE.md §20).
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

  const ExecutableReading.unchecked(this.path)
    : reachability = ExecutableReachability.unchecked,
      resolved = null;

  final String path;

  final ExecutableReachability reachability;

  /// A usable spelling of the same executable, reached by following [path]'s
  /// reparse points. Non-null is the repairable case; null includes [usable],
  /// which needs no substitute.
  final String? resolved;

  bool get isUsable => reachability == ExecutableReachability.usable;

  bool get isRepairable => resolved != null;
}

/// How [path] answered, according to [probe].
///
/// **The reparse walk is the discriminator, not an exception**: a path behind an
/// untraversable junction answers `existsSync` exactly as an uninstalled CLI
/// does, so absence is only established by completing the route.
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
    // The route completed and the file is gone.
    if (behind == false && direct == false) {
      return ExecutableReading(
        path: path,
        reachability: ExecutableReachability.missing,
      );
    }
  }

  return ExecutableReading(
    path: path,
    // A chain that could not be walked, or an OS that declined outright:
    // nothing was established, so nothing is claimed.
    reachability: (resolved == null || direct == null)
        ? ExecutableReachability.unreachable
        : ExecutableReachability.missing,
  );
}

/// [path] with every reparse point on the way to it replaced by its target, or
/// `null` when the chain cannot be followed.
///
/// Component by component, because `resolveSymbolicLinksSync` and every other
/// whole-path call throws on a junction chain the OS refuses to traverse.
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
/// `redirected: false` is a finished answer; `redirected: true` with a null path
/// is a dead end. Collapsing them would hand a caller an unresolved path to
/// store as if it were resolved.
({bool redirected, String? path}) _followFirstLink(
  String path,
  PathProbe probe,
  p.Context ctx,
) {
  final parts = ctx.split(path);
  // From 1: the root is never a reparse point and costs a syscall per hop.
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

/// The traversable spelling of [path]: itself when already usable, otherwise the
/// reparse-resolved path when *that* is usable, otherwise `null`. A working path
/// is never traded for whatever it happens to point at today.
String? traversablePath(String path, PathProbe probe, {p.Context? context}) {
  final reading = readExecutable(path, probe, context: context);
  return reading.isUsable ? reading.path : reading.resolved;
}

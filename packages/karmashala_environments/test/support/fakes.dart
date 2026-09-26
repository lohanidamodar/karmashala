import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';

/// A [Clock] that always returns a fixed instant.
class FixedClock implements Clock {
  FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime nowUtc() => _now.toUtc();
}

/// An [IdGenerator] that returns predictable, sequential ids (`id-0`, `id-1`…).
class SequentialIdGenerator implements IdGenerator {
  SequentialIdGenerator([this._prefix = 'id-']);
  final String _prefix;
  int _next = 0;
  @override
  String newId() => '$_prefix${_next++}';
}

/// A deterministic [CommandRunner]: records every request it is asked and
/// answers through [responder] (or a default success), or throws [throwError]
/// the way a missing executable or an unavailable environment does.
class FakeCommandRunner implements CommandRunner {
  FakeCommandRunner({
    this.environmentId = 'windows',
    this.responder,
    this.throwError,
  });

  @override
  final String environmentId;

  CommandResult Function(CommandRequest request)? responder;
  Object? throwError;

  /// Every request received, in order — the count a test holds a sweep to.
  final List<CommandRequest> requests = [];

  @override
  Future<CommandResult> run(CommandRequest request) async {
    requests.add(request);
    if (throwError != null) throw throwError!;
    return responder?.call(request) ??
        const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) =>
      throw UnsupportedError('the sweep never starts a long-running process');
}

/// A described disk: which files exist, which components are reparse points
/// and where they lead, and which paths the OS refuses to answer about.
///
/// Nothing here touches a real filesystem, so a test can describe the owner's
/// broken junction chain on any host, and the suite never depends on whether
/// an agent happens to be installed on the machine running it.
class FakePathProbe implements PathProbe {
  FakePathProbe({
    Set<String> files = const {},
    Map<String, String> links = const {},
    Set<String> refused = const {},
  }) : files = {...files},
       links = {...links},
       refused = {...refused};

  final Set<String> files;
  final Map<String, String> links;
  final Set<String> refused;

  @override
  bool? fileExists(String path) {
    if (refused.any(
      (r) => path == r || path.startsWith('$r\\') || path.startsWith('$r/'),
    )) {
      return null;
    }
    return files.contains(path);
  }

  @override
  bool isLink(String path) => links.containsKey(path);

  @override
  String? linkTarget(String path) => links[path];
}

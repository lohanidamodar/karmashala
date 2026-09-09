import 'package:agent_cli/discovery.dart' as agent_cli;
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/repositories/data/checkout_presence_probe.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/git/data/git_files.dart';
import 'package:karmashala/src/features/repositories/data/repository_discovery_service.dart';
import 'package:karmashala/src/features/repositories/domain/discovered_repository.dart';

/// A [Clock] that always returns a fixed instant.
///
/// It implements the package's copy of the interface as well as core's.
/// `agent_cli` is published and carries verbatim copies of `Clock` and
/// `IdGenerator` rather than depending on `karmashala_core` for them
/// (docs/PACKAGE_SPLIT.md §2); one fake satisfying both is what keeps every
/// suite that pins a time or an id on a single double.
class FixedClock implements Clock, agent_cli.Clock {
  FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime nowUtc() => _now.toUtc();
}

/// A [Clock] a test can move, for the schedules a fixed instant cannot show.
///
/// Satisfies both copies of the interface, for the same reason [FixedClock]
/// does.
class MovableClock implements Clock, agent_cli.Clock {
  MovableClock(this.now);

  DateTime now;

  @override
  DateTime nowUtc() => now.toUtc();

  void advance(Duration by) => now = now.add(by);
}

/// An [IdGenerator] that returns predictable, sequential ids (`id-0`, `id-1`…).
class SequentialIdGenerator implements IdGenerator, agent_cli.IdGenerator {
  SequentialIdGenerator([this._prefix = 'id-']);
  final String _prefix;
  int _next = 0;
  @override
  String newId() => '$_prefix${_next++}';
}

/// A [RepositoryDiscoveryService] returning a preset result (or throwing a
/// preset error), so use-cases can be tested without touching the filesystem.
class FakeRepositoryDiscoveryService implements RepositoryDiscoveryService {
  FakeRepositoryDiscoveryService({this.result = const [], this.error});

  /// Repositories to return from [discover].
  List<DiscoveredRepository> result;

  /// If set, [discover] throws this instead of returning [result].
  Object? error;

  /// Records the roots discovery was invoked with.
  final List<EnvironmentPath> calls = [];

  @override
  Future<List<DiscoveredRepository>> discover(
    EnvironmentPath root, {
    int maxDepth = 5,
  }) async {
    calls.add(root);
    if (error != null) throw error!;
    return result;
  }
}

/// A presence probe that answers from a table and never touches a filesystem.
///
/// Retirement asks whether a directory is still there, and in production that
/// is a bounded `Directory.exists` — a real async call with a real timer
/// behind its deadline. A widget test that drives a rescan would otherwise
/// leave both outliving the tree it was pumped in. `unknown` is the default
/// because it is the answer that never retires anything.
class FakeCheckoutPresenceProbe implements CheckoutPresenceProbe {
  FakeCheckoutPresenceProbe([this.answers = const {}]);

  /// Keyed by path, as the caller spells it.
  final Map<String, CheckoutPresence> answers;

  @override
  Future<CheckoutPresence> presenceOf(
    EnvironmentPath directory, {
    required ExecutionEnvironment environment,
    required ExecutionEnvironment windows,
  }) async => answers[directory.path] ?? CheckoutPresence.unknown;
}

/// The probe gate for a container that has no widget tree: no wait at all.
///
/// Hand it to `probeGateProvider.overrideWithValue`. A checkout's git probes
/// wait for the frame that asked for them to finish before they spawn anything
/// — see `checkout_probe_queue.dart` for why a `Process.run` is charged to the
/// frame that calls it. A `ProviderContainer` with no widget tree pumps no
/// frames, so the real gate schedules one, nothing ever draws it, and a
/// delivery reading **hangs** rather than failing. Every container that reaches
/// those providers therefore needs this, including a widget test that reads a
/// delivery future without pumping.
///
/// **The gate function rather than the `Override`**, deliberately: `Override`
/// is a sealed type Riverpod's public library does not export, so a helper
/// returning one is untypeable — and an untyped one turns
/// `fakeTerminalOverrides`' own inferred `List<Override>` into a
/// `List<dynamic>`, which fails at the container and nowhere near here. Cost
/// one full gate to learn.
Future<void> headlessProbeGate() async {}

/// `.git` for a test that is not about `.git`: **every read answers nothing**,
/// so `ChangesService.originFacts` falls back to `git` exactly as it did before
/// there was anything to read.
///
/// Hand it to `gitFilesProvider.overrideWithValue`, or take the default from
/// `fakeTerminalOverrides`. Every container that reaches the delivery providers
/// needs it, and for a sharper reason than tidiness: `HostGitFiles` performs
/// **real** file I/O, whose completion is a real event-loop callback that
/// `testWidgets`' fake-async clock does not control. The extra async gap it
/// opens is enough to reorder a build against an invalidation — measured, on
/// this change: twenty-three tests across seven files failed, and the loudest
/// of them died inside `sessionDeliveryProvider` with *"Cannot use the Ref …
/// after it has been disposed"*, a pre-existing `ref.read`-after-await that had
/// simply never been given a wide enough gap to lose the race. A test suite
/// that reads the machine it runs on is the problem; this is the fix.
///
/// So the read path is exercised only where a test opts in by handing over its
/// own [GitFiles] — `git_origin_reader_test.dart`, `changes_service_test.dart`
/// and `checkout_scale_cost_test.dart`, which is where that path lives.
class NoGitFiles implements GitFiles {
  const NoGitFiles();

  @override
  Future<String?> readString(String path) async => null;

  @override
  Future<bool> exists(String path) async => false;

  /// Nothing is there — **not even the checkout folder**, so `GitPresenceReader`
  /// answers `unknown` and every provider gating on it still asks git. Tests
  /// that are *about* the probe hand over their own [GitFiles].
  @override
  Future<PathEntry> typeOf(String path) async => PathEntry.none;

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<void> writeString(String path, String contents) async {}
}

/// The one every test shares; see [NoGitFiles].
const noGitFiles = NoGitFiles();

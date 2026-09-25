import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/database_providers.dart';
import '../../browser/application/browser_providers.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_session/session.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'package:karmashala_verification/store.dart';
import '../domain/session_verdict.dart';
import 'package:karmashala_verification/verification.dart';
import 'verification_service.dart';
import '../../../core/paths/app_support_directory.dart';

final verificationDaoProvider = Provider<VerificationDao>(
  (ref) => VerificationDao(ref.watch(databaseProvider)),
);

/// Where run directories live: `<application support>/verification`, resolved
/// once. Read it late or not at all — before [resolveVerificationRoot] is
/// awaited it throws, and Riverpod caches that throw for the whole process.
final verificationRootProvider = Provider<Directory>((ref) {
  final root = _resolvedRoot;
  if (root == null) {
    throw StateError(
      'verificationRootProvider must be overridden, or '
      'resolveVerificationRoot() awaited during bootstrap.',
    );
  }
  return root;
});

Directory? _resolvedRoot;

/// Resolves and remembers the artifact root: bootstrap, and the control server
/// before it first serves a verification tool.
Future<Directory> resolveVerificationRoot() async {
  final existing = _resolvedRoot;
  if (existing != null) return existing;
  final support = await appSupportDirectory();
  final root = Directory(p.join(support.path, 'verification'));
  await root.create(recursive: true);
  return _resolvedRoot = root;
}

/// Resolves the artifact root once — the pane waits on this rather than
/// assume bootstrap already ran.
final verificationRootReadyProvider = FutureProvider<Directory>(
  (ref) => resolveVerificationRoot(),
);

final verificationArtifactStoreProvider = Provider<VerificationArtifactStore>(
  (ref) => VerificationArtifactStore(ref.watch(verificationRootProvider)),
);

/// The "a run started, stepped or finished" signal. Depends on nothing: hung
/// off [VerificationService] it reached [verificationRootProvider] on the
/// warm-up frame, and the throw Riverpod cached there errored the feature.
final verificationChangesProvider = Provider<VerificationChangeSignal>((ref) {
  final signal = VerificationChangeSignal();
  ref.onDispose(signal.dispose);
  return signal;
});

/// The one recorder. Long-lived: disposing it mid-run leaves its sinks in.
final verificationServiceProvider = Provider<VerificationService>((ref) {
  final service = VerificationService(
    ref.watch(verificationDaoProvider),
    ref.watch(verificationArtifactStoreProvider),
    browserOf: () => ref.read(browserServiceProvider),
    adbOf: () => ref.read(adbServiceProvider),
    changes: ref.watch(verificationChangesProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Bumped whenever a run starts, steps or finishes, so the pane rebuilds.
final verificationRevisionProvider = StreamProvider<void>(
  (ref) => ref.watch(verificationChangesProvider).stream,
);

/// Runs newest first, for the pane's list.
final verificationRunsProvider = Provider<List<VerificationRun>>((ref) {
  ref.watch(verificationRevisionProvider);
  return ref.watch(verificationServiceProvider).list();
});

/// One run with its steps and artifacts.
final verificationRunProvider = Provider.family<VerificationRun?, String>((
  ref,
  id,
) {
  ref.watch(verificationRevisionProvider);
  return ref.watch(verificationServiceProvider).get(id);
});

/// What one session's verification record amounts to, in one word. Reads the
/// two DAOs, never [verificationServiceProvider], which would need
/// [verificationRootProvider] resolved on a frame every session view draws.
final sessionVerdictProvider = Provider.family<SessionVerdict, String>((
  ref,
  sessionId,
) {
  ref.watch(verificationRevisionProvider);
  // The row's status decides recorded-vs-abandoned; narrowed to that row.
  ref.watchSession(sessionId);
  final session = ref.watch(sessionDaoProvider).getById(sessionId);
  return SessionVerdict.of(
    ref.watch(verificationDaoProvider).listRuns(sessionId: sessionId),
    // A session that has gone is one nothing will finish a run for either.
    sessionHasEnded: session == null || endingOfStatus(session.status) != null,
  );
});

/// Which run the pane has open.
final selectedVerificationRunProvider =
    NotifierProvider<SelectedVerificationRun, String?>(
      SelectedVerificationRun.new,
    );

class SelectedVerificationRun extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

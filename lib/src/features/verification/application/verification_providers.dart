import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/database/database_providers.dart';
import '../../browser/application/browser_providers.dart';
import '../../devices/application/device_providers.dart';
import '../../follow_ups/domain/session_ending.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../data/verification_artifact_store.dart';
import '../data/verification_dao.dart';
import '../domain/session_verdict.dart';
import '../domain/verification_run.dart';
import 'verification_service.dart';

final verificationDaoProvider = Provider<VerificationDao>(
  (ref) => VerificationDao(ref.watch(databaseProvider)),
);

/// Where run directories live: `<application support>/verification`.
///
/// Resolved once and cached, because the store is created synchronously by the
/// service provider and asking the platform on every call would make every
/// write a future for no reason.
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

/// Resolves and remembers the artifact root. Called during bootstrap, and by
/// the control server before it first serves a verification tool.
Future<Directory> resolveVerificationRoot() async {
  final existing = _resolvedRoot;
  if (existing != null) return existing;
  final support = await getApplicationSupportDirectory();
  final root = Directory(p.join(support.path, 'verification'));
  await root.create(recursive: true);
  return _resolvedRoot = root;
}

/// Resolves the artifact root once, for whoever needs the feature to be usable
/// before it is read — the pane waits on this rather than assuming bootstrap
/// already ran.
final verificationRootReadyProvider = FutureProvider<Directory>(
  (ref) => resolveVerificationRoot(),
);

final verificationArtifactStoreProvider = Provider<VerificationArtifactStore>(
  (ref) => VerificationArtifactStore(ref.watch(verificationRootProvider)),
);

/// The one recorder. Long-lived: it installs sinks on the app's single browser
/// and adb services, and disposing it mid-run would leave them installed.
final verificationServiceProvider = Provider<VerificationService>((ref) {
  final service = VerificationService(
    ref.watch(verificationDaoProvider),
    ref.watch(verificationArtifactStoreProvider),
    browserOf: () => ref.read(browserServiceProvider),
    adbOf: () => ref.read(adbServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Bumped whenever a run starts, steps or finishes, so the pane rebuilds.
final verificationRevisionProvider = StreamProvider<void>(
  (ref) => ref.watch(verificationServiceProvider).changes,
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

/// What one session's verification record amounts to, in one word.
///
/// Reads the two DAOs and nothing else — deliberately **not**
/// [verificationServiceProvider], which builds an artifact store and therefore
/// needs [verificationRootProvider] resolved. This answer is drawn on the
/// delivery strip, which every session view hosts, and a strip that threw
/// because bootstrap had not reached the filesystem yet would take the whole
/// session pane with it.
///
/// [verificationRevisionProvider] is watched for its *notifications* rather
/// than its value, so a run that starts or finishes redraws the strip. It is
/// read as an `AsyncValue`, which is what makes the paragraph above hold: a
/// container with no artifact root gets an error state and no live updates
/// instead of an exception.
final sessionVerdictProvider = Provider.family<SessionVerdict, String>((
  ref,
  sessionId,
) {
  ref.watch(verificationRevisionProvider);
  // The row's own status decides whether an open run is being recorded or was
  // abandoned, so a status change has to reach this. Narrowed to the row: a
  // rename elsewhere in the workspace says nothing about this answer.
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

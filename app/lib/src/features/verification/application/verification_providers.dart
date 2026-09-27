import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/data/data_providers.dart';
import 'package:karmashala_session/session.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        VerificationEvidenceAdded,
        VerificationRunChanged,
        VerificationRunRemoved;
import 'package:karmashala_verification/artifacts.dart';
import '../data/verification_data.dart';
import '../domain/session_verdict.dart';
import 'package:karmashala_verification/verification.dart';
import 'verification_service.dart';
import '../../../core/paths/server_data_directory.dart';

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
  // Beside the store, where the server writes the gates it runs itself.
  final data = await serverDataDirectory();
  final root = Directory(p.join(data.path, 'verification'));
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

/// The "a run started, stepped or finished" signal — here or at another
/// client. Kept off [VerificationService]: hung there it reached
/// [verificationRootProvider] on the warm-up frame, whose throw Riverpod caches.
final verificationChangesProvider = Provider<VerificationChangeSignal>((ref) {
  final signal = VerificationChangeSignal();
  final listening = ref.watch(dataClientProvider).evidenceChanges.listen((
    change,
  ) {
    if (change is VerificationRunChanged ||
        change is VerificationRunRemoved ||
        change is VerificationEvidenceAdded) {
      signal.bump();
    }
  });
  ref.onDispose(() {
    listening.cancel();
    signal.dispose();
  });
  return signal;
});

/// The runs as this app reads them; the server records every one.
final verificationServiceProvider = Provider<VerificationService>((ref) {
  final service = VerificationService(
    ref.watch(verificationDataProvider),
    ref.watch(verificationArtifactStoreProvider),
    changes: ref.watch(verificationChangesProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Bumped whenever a run starts, steps or finishes, so the pane rebuilds.
final verificationRevisionProvider = StreamProvider<void>(
  (ref) => ref.watch(verificationChangesProvider).stream,
);

/// Runs newest first, whole, for the pane's list.
final verificationRunsProvider = FutureProvider<List<VerificationRun>>((ref) {
  ref.watch(verificationRevisionProvider);
  return ref.watch(verificationServiceProvider).list();
});

/// One run with its steps and artifacts.
final verificationRunProvider = FutureProvider.family<VerificationRun?, String>(
  (ref, id) {
    ref.watch(verificationRevisionProvider);
    return ref.watch(verificationServiceProvider).get(id);
  },
);

/// What one session's verification record amounts to, in one word. Reads the
/// copied headers, never [verificationServiceProvider], which would need
/// [verificationRootProvider] resolved on a frame every session view draws.
final sessionVerdictProvider = Provider.family<SessionVerdict, String>((
  ref,
  sessionId,
) {
  ref.watch(verificationRevisionProvider);
  // The row's status decides recorded-vs-abandoned; narrowed to that row.
  ref.watchSession(sessionId);
  final session = ref.watch(sessionsDataProvider).getById(sessionId);
  return SessionVerdict.of(
    ref.watch(verificationDataProvider).headersOf(sessionId),
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

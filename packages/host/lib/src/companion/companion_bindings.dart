import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import '../domain/host_session.dart';
import '../domain/session_lifecycle.dart';
import '../domain/session_registry.dart';

/// What this host can answer a companion **today**, and an honest refusal for
/// everything else.
///
/// The desktop's bindings read the app's providers; a host on a machine with no
/// GUI has only the sessions it owns. So `listSessions` and `sessionById` are
/// real and the rest refuse by name — a phone is told "this host does not do
/// that yet" rather than being handed an empty transcript it would render as a
/// session with nothing in it (§19).
///
/// Nothing here may await anything a UI frame gates. That is not a style rule:
/// `checkoutProbeQueueProvider` waits on `SchedulerBinding.endOfFrame`, a
/// desktop that is not rendering pumps none, and the phone sat on a link that
/// was alive but silent (fixed on the desktop side in `91a457db`). A host has no
/// frames at all, so the same await would never complete here.
RemoteHostBindings hostCompanionBindings(
  SessionRegistry registry, {
  required String hostName,
}) {
  // `unknownType` rather than `notPermitted`: nothing was withheld from this
  // client, the host simply does not serve that frame. The protocol has no
  // "understood but unimplemented" code and adding one is a protocol change.
  Never notHere(String what) => throw RemoteApiRefusal(
    ErrorCode.unknownType,
    '$what is not something a session host answers yet.',
  );

  return RemoteHostBindings(
    hostName: hostName,
    listSessions: () => [
      for (final session in registry.sessions) _snapshot(session, hostName),
    ],
    sessionById: (id) {
      final session = registry.find(id);
      return session == null ? null : _snapshot(session, hostName);
    },
    // Null is already "could not tell" on this binding, and a host genuinely
    // cannot: delivery is a git/gh reading the desktop owns.
    deliveryStageFor: (_) async => null,
    transcriptFor: (_) async => notHere('reading a transcript'),
    sendPrompt: (_, _, {attachment}) async => notHere('sending a prompt'),
    answerApproval: (_, _) async => notHere('answering an approval'),
    approvalEvidenceFor: (_) async => notHere('reading an approval'),
    registerPush: (_, _, _, _) async => notHere('push'),
    listWorkspace: () => const [],
    listProjects: () => const [],
    startSession: (_) async => notHere('starting a session'),
    addProject: (_, _) async => notHere('adding a project'),
    resumeSession: (_) async => notHere('resuming a session'),
    beginAttachment: (_, _) async => notHere('an attachment'),
    writeAttachmentChunk: (_, _, _, _) async => notHere('an attachment'),
    discardAttachment: (_) async {},
  );
}

/// One host session as the phone's list renders it. The title is the command,
/// because it is the only name this machine has for the session — the desktop's
/// own titles live in a store the host does not read yet.
///
/// `whereabouts` is the *machine*, not the directory: it is prose the phone
/// shows verbatim ("running here" on the desktop), and which box a session is
/// on is the fact a companion talking straight to one needs.
RemoteSessionSnapshot _snapshot(HostSession session, String hostName) =>
    RemoteSessionSnapshot(
      sessionId: session.id,
      title: session.request.argv.isEmpty
          ? session.id
          : session.request.argv.join(' '),
      status: switch (session.lifecycle) {
        SessionRunning() => 'running',
        SessionExited(:final code) => code == 0 ? 'finished' : 'failed',
        SessionEndedWithoutCode() => 'finished',
      },
      createdAt: session.startedAt.toUtc().toIso8601String(),
      whereabouts: 'on $hostName',
    );

import 'package:karmashala_remote/remote.dart';

/// What one capability is called wherever a grant is shown or edited — the
/// pairing dialog and the paired device's permissions. One list, so a phone
/// cannot be granted "See usage limits" in one place and "Usage" in another.
String capabilityLabel(Capability capability) => switch (capability) {
  Capability.viewSessions => 'View sessions',
  Capability.readTranscript => 'Read transcripts',
  Capability.sendPrompt => 'Send prompts',
  Capability.approve => 'Answer approvals',
  Capability.receiveNotifications => 'Notifications',
  Capability.startSession => 'Start new sessions',
  Capability.addProject => 'Add projects',
  Capability.viewActivity => 'See what is running',
  Capability.sendAttachment => 'Send files',
  Capability.viewUsage => 'See usage limits',
  Capability.desktopClient => 'Use as a desktop client',
  Capability.serverAdmin => 'Administer this server',
  Capability.sshPrompts => 'Answer SSH questions',
  Capability.phoneClient =>
    'Use the Karmashala app on a phone (sessions, terminals, files)',
};

/// The bits this build knows how to show. Anything outside it — a grant made
/// by a newer build — is carried through an edit untouched rather than
/// silently dropped by a dialog that cannot draw it.
int get knownCapabilityBits =>
    Capability.values.fold(0, (bits, c) => bits | c.bit);

/// [granted] with this build's bits replaced by [chosen], and every bit it
/// does not know left exactly as it was.
CapabilitySet capabilitiesWith(
  CapabilitySet granted,
  Iterable<Capability> chosen,
) => CapabilitySet(
  (granted.bits & ~knownCapabilityBits) | CapabilitySet.of(chosen).bits,
);

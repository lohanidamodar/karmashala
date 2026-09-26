import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_remote/remote.dart';

import '../store/companion_attachment_store.dart';

/// What a file sent to a session of [descriptor]'s agent may be, by what the
/// agent declares alone — whoever serves the phone then asks whether a path it
/// writes is one that agent can open (the same machine, or a WSL beside it).
RemoteAttachmentSupport agentAttachmentSupport(AgentDescriptor? descriptor) {
  final support = descriptor?.attachments;
  if (support == null || !support.isSupported) {
    return RemoteAttachmentSupport.refused(
      support?.refusal.isNotEmpty ?? false
          ? support!.refusal
          : 'This agent is not known to open a file named in a prompt.',
    );
  }
  return RemoteAttachmentSupport(
    mediaTypes: [
      for (final type in support.mediaTypes)
        // Only what can also be *written*: a type the agent would read but the
        // store has no extension for is a path nobody can open.
        if (kAttachmentExtensions.containsKey(type)) type,
    ],
    maxBytes: kMaxAttachmentBytes,
  );
}

/// The prompt that hands an agent a file at [path], in the desktop composer's
/// own words, so an agent cannot tell which door the file came through.
String attachmentPromptBody(String text, String path) => text.isEmpty
    ? 'Attached image(s):\n$path'
    : '$text\n\nAttached image(s):\n$path';

import 'package:agent_cli/process.dart'
    show
        EnvironmentKind,
        EnvironmentPath,
        PathTranslationException,
        PathTranslator,
        localHostEnvironmentId,
        posixQuote;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../agents/data/agents_data.dart';
import '../../environments/data/environments_data.dart';
import '../../sessions/application/session_providers.dart';
import '../../snippets/application/snippet_insertion.dart';
import '../../snippets/domain/command_snippet.dart';
import '../../terminal/application/terminal_sessions_controller.dart';

/// Text queued for a session's message composer, keyed by session id: **a note
/// is not sent, it is offered**. The draft waits until the composer takes it.
class ComposerDrafts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  /// Offers [text] to [sessionId]'s composer. A second offer before the first
  /// is taken appends rather than replaces: two notes sent back in a row are
  /// two ideas, and losing one silently is the worse failure.
  void queue(String sessionId, String text) {
    final pending = state[sessionId];
    state = {
      ...state,
      sessionId: pending == null || pending.isEmpty
          ? text
          : '$pending\n\n$text',
    };
  }

  /// Takes whatever is waiting for [sessionId], leaving nothing behind.
  String? take(String sessionId) {
    final pending = state[sessionId];
    if (pending == null) return null;
    state = {...state}..remove(sessionId);
    return pending;
  }
}

final composerDraftProvider =
    NotifierProvider<ComposerDrafts, Map<String, String>>(ComposerDrafts.new);

/// Files queued for a session's composer as attachments, keyed by session id —
/// [ComposerDrafts]' twin for a file rather than words. Each is **already
/// spelled for the session's agent** (see [agentPathOf]): the composer is
/// sent a path it hands on as it is, never one it would have to translate.
///
/// A file here is on the server's disk, so nothing is ever uploaded for it;
/// the composer draws it as an attachment *from Files* and lists its path to
/// the agent the way it lists any other.
class ComposerAttachments extends Notifier<Map<String, List<EnvironmentPath>>> {
  @override
  Map<String, List<EnvironmentPath>> build() => const {};

  /// Queues [file] for [sessionId]'s composer, after anything already waiting.
  /// The same file twice is one attachment: a second *Attach to chat* on an
  /// open tab is a repeat of the first, not a request for two copies.
  void queue(String sessionId, EnvironmentPath file) {
    final pending = state[sessionId] ?? const <EnvironmentPath>[];
    if (pending.contains(file)) return;
    state = {
      ...state,
      sessionId: List.unmodifiable([...pending, file]),
    };
  }

  /// Takes every file waiting for [sessionId], leaving nothing behind.
  List<EnvironmentPath>? take(String sessionId) {
    final pending = state[sessionId];
    if (pending == null) return null;
    state = {...state}..remove(sessionId);
    return pending;
  }
}

final composerAttachmentsProvider =
    NotifierProvider<ComposerAttachments, Map<String, List<EnvironmentPath>>>(
      ComposerAttachments.new,
    );

/// Where a note or a todo went when it was offered to a session.
enum SessionOfferOutcome {
  /// Typed at the session's prompt and left there, because its terminal is the
  /// face on screen.
  typedIntoTerminal,

  /// Queued for the composer, because its conversation is the face on screen.
  queuedForComposer,

  /// Queued, and nothing is showing it: the session runs in no live pane.
  waitingForAPane,

  /// Neither typed nor queued: a file the session's agent cannot reach — on an
  /// SSH host while the agent runs elsewhere, or between two environments with
  /// no path translation. Only a file offer answers this; text always lands.
  outOfReach,
}

/// Offers [text] to [sessionId] in the face that session is already showing —
/// typed at a prompt, or queued for a composer. The face is read, never written.
SessionOfferOutcome offerToSession(
  WidgetRef ref, {
  required String sessionId,
  required String text,
}) => offerToSessionWith(ref.read, sessionId: sessionId, text: text);

/// [offerToSession] through any reader — a provider's `ref.read` too: an
/// agent's `session_draft` arrives as a server intent, with no widget.
SessionOfferOutcome offerToSessionWith(
  T Function<T>(ProviderListenable<T> provider) read, {
  required String sessionId,
  required String text,
}) => _offer(
  _Reader(read),
  sessionId: sessionId,
  typed: text,
  park: (ref) =>
      ref.read(composerDraftProvider.notifier).queue(sessionId, text),
);

/// Offers [file] to [sessionId] the way [offerToSession] offers text, in the
/// face the session is showing: its path typed at the terminal's prompt —
/// quoted when it has spaces, never submitted — or the file queued for the
/// composer as an attachment ([composerAttachmentsProvider]).
///
/// Either way the path is the one the **agent** reads ([agentPathOf]): a
/// Windows file offered to a WSL session goes as `/mnt/c/…`. A file the agent
/// cannot reach is neither typed nor queued, and says so —
/// [SessionOfferOutcome.outOfReach].
SessionOfferOutcome offerFileToSession(
  WidgetRef ref, {
  required String sessionId,
  required EnvironmentPath file,
}) => offerFileToSessionWith(ref.read, sessionId: sessionId, file: file);

/// [offerFileToSession] through any reader.
SessionOfferOutcome offerFileToSessionWith(
  T Function<T>(ProviderListenable<T> provider) read, {
  required String sessionId,
  required EnvironmentPath file,
}) {
  final reader = _Reader(read);
  final spelled = agentPathOf(read, sessionId: sessionId, file: file);
  if (spelled == null) return SessionOfferOutcome.outOfReach;
  return _offer(
    reader,
    sessionId: sessionId,
    typed: _quotedFor(read, spelled),
    park: (ref) => ref
        .read(composerAttachmentsProvider.notifier)
        .queue(sessionId, spelled),
  );
}

/// [file] as [sessionId]'s agent spells it — an [EnvironmentPath] in the
/// agent's own environment — or null when the agent cannot reach it.
///
/// The agent's environment is its installation's; a session whose
/// installation is unknown is taken to run on the server's own host, which is
/// what the composer's attach picker assumes too. Same environment: the path
/// as it is. Windows ⇄ WSL: [PathTranslator]. Anything else — an SSH host on
/// either side of the pair, two WSL distributions, an environment this client
/// has no row for — is out of reach: a path typed there would name nothing,
/// or worse, a different file.
EnvironmentPath? agentPathOf(
  T Function<T>(ProviderListenable<T> provider) read, {
  required String sessionId,
  required EnvironmentPath file,
}) {
  final session = read(sessionsDataProvider).getById(sessionId);
  final installation = session == null
      ? null
      : read(
          agentInstallationsDataProvider,
        ).getById(session.agentInstallationId);
  final agentEnvironmentId =
      installation?.environmentId ?? localHostEnvironmentId;
  if (agentEnvironmentId == file.environmentId) return file;
  final environments = read(environmentsDataProvider);
  final from = environments.getById(file.environmentId);
  final to = environments.getById(agentEnvironmentId);
  if (from == null || to == null) return null;
  try {
    return const PathTranslator().translate(file, from: from, to: to);
  } on PathTranslationException {
    return null;
  }
}

/// [path] as it is typed at a prompt in its environment: bare when it has no
/// whitespace, else double-quoted on Windows and single-quoted elsewhere —
/// what `cmd`, PowerShell, a POSIX shell and the agents' own prompts all read
/// back as one path.
String _quotedFor(
  T Function<T>(ProviderListenable<T> provider) read,
  EnvironmentPath path,
) {
  final text = path.path;
  if (!text.contains(RegExp(r'\s'))) return text;
  final kind = read(environmentsDataProvider).getById(path.environmentId)?.kind;
  return kind == EnvironmentKind.windowsNative ? '"$text"' : posixQuote(text);
}

/// The one body behind every offer: [typed] into the session's terminal when
/// that is the face on screen, else [park]ed for its composer.
SessionOfferOutcome _offer(
  _Reader ref, {
  required String sessionId,
  required String typed,
  required void Function(_Reader ref) park,
}) {
  // Answered before the terminals are read at all: a session no window ever
  // opened in a pane has no face to follow, and mounting the controller to
  // find that out would start the pane machinery for a panel that never
  // needed it. The row only says *whether*; this window's pane is the index's.
  final placed = ref.read(sessionsDataProvider).getById(sessionId)?.paneId;
  final paneId = placed == null
      ? null
      : ref.read(paneSessionsProvider).paneOf(sessionId);
  if (paneId == null) {
    park(ref);
    return SessionOfferOutcome.waitingForAPane;
  }
  final terminals = ref.read(terminalSessionsControllerProvider.notifier);
  final state = ref.read(terminalSessionsControllerProvider);
  // No group means no face to follow — a pane the layout has lost. Treated as
  // the composer, which is the destination that keeps the text.
  final groupId = terminals.groupOfPane(paneId);
  if (groupId != null &&
      ref.read(terminalVisibleInGroupProvider(groupId)) &&
      insertSnippet(
        terminals: terminals,
        state: state,
        snippet: _offered(typed),
        paneId: paneId,
      ).delivered) {
    return SessionOfferOutcome.typedIntoTerminal;
  }
  park(ref);
  // A pane whose process has exited cannot be typed into and shows no
  // composer either, so it is waiting rather than delivered.
  return state.livenessOf(paneId).isLive
      ? SessionOfferOutcome.queuedForComposer
      : SessionOfferOutcome.waitingForAPane;
}

/// A reader standing in for a ref, so one body serves both kinds.
class _Reader {
  const _Reader(this.read);

  final T Function<T>(ProviderListenable<T> provider) read;
}

/// What the user is offered, said the one way that will not be misread.
String sessionOfferMessage(SessionOfferOutcome outcome, String title) =>
    switch (outcome) {
      SessionOfferOutcome.typedIntoTerminal =>
        'Typed into $title’s terminal, unsent.',
      SessionOfferOutcome.queuedForComposer => 'Sent to $title’s message box.',
      SessionOfferOutcome.waitingForAPane =>
        'Waiting for $title — no terminal is running it.',
      SessionOfferOutcome.outOfReach =>
        'Not attached: $title’s agent cannot reach that file from where it '
            'runs.',
    };

/// [text] as [insertSnippet] takes it: a one-line command, never submitted.
/// A throwaway rather than a second write path.
CommandSnippet _offered(String text) => CommandSnippet(
  id: 'offered',
  label: 'Offered text',
  command: text,
  createdAt: DateTime.utc(1970),
  updatedAt: DateTime.utc(1970),
);

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
import 'package:karmashala_terminal_core/profiles.dart' show TerminalShell;

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

  /// Takes every file waiting for [sessionId], leaving nothing behind. Called
  /// only by a composer that attaches them in the same breath: a file taken
  /// and then refused would be lost after the user was told it was sent, so a
  /// composer that cannot attach right now leaves them here.
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
  typed: (_) => text,
  park: (ref) =>
      ref.read(composerDraftProvider.notifier).queue(sessionId, text),
);

/// Offers [file] to [sessionId] the way [offerToSession] offers text, in the
/// face the session is showing: its path typed at the terminal's prompt —
/// quoted unless it is all plain characters ([quotePathForPrompt]), never
/// submitted — or the file queued for the
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
    typed: (target) => _quotedFor(read, spelled, target),
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

/// How a prompt reads a quoted path.
enum PromptQuoting {
  /// PowerShell, and an agent CLI on Windows: `'…'`, quotes doubled.
  powerShell,

  /// cmd.exe: `"…"`. Windows forbids `"` in a name, so nothing needs escaping
  /// inside; `%NAME%` still expands there, and cmd offers no quoting that
  /// stops it at an interactive prompt — a path holding one is rare enough to
  /// leave as it is.
  commandPrompt,

  /// bash, zsh, fish, WSL, an SSH host: [posixQuote].
  posix,
}

/// [path] as it is typed at the prompt of [target], the pane it is typed into.
/// A **shell pane** says which shell it runs (the same reading snippets take,
/// [snippetTargetFor]), and that shell's quoting is used. An **agent pane**,
/// or a pane whose shell is unknown, falls back to the environment's kind: a
/// [EnvironmentKind.windowsNative] one PowerShell's, any other (or one this
/// client has no row for) a POSIX shell's.
String _quotedFor(
  T Function<T>(ProviderListenable<T> provider) read,
  EnvironmentPath path,
  SnippetTarget? target,
) {
  final byShell = target == null || target.isAgentPane
      ? null
      : switch (target.shell) {
          TerminalShell.powerShell => PromptQuoting.powerShell,
          TerminalShell.commandPrompt => PromptQuoting.commandPrompt,
          TerminalShell.wsl ||
          TerminalShell.posix ||
          TerminalShell.ssh => PromptQuoting.posix,
          null => null,
        };
  final kind = read(environmentsDataProvider).getById(path.environmentId)?.kind;
  return quotePathFor(
    path.path,
    byShell ??
        (kind == EnvironmentKind.windowsNative
            ? PromptQuoting.powerShell
            : PromptQuoting.posix),
  );
}

/// The characters a path may hold and still be typed bare: anything else — a
/// space, a quote, `&`, `$`, a backtick, a bracket — is something some shell
/// reads as syntax, so the path is quoted whole.
final _bareSafe = RegExp(r'^[A-Za-z0-9_./:\\-]+$');

/// [path] spelled so a prompt reads it back as exactly one path, never run.
/// Bare when every character is in [_bareSafe]. Otherwise single-quoted:
/// on Windows ([windows]) PowerShell's way, each quote doubled
/// (`'it''s.png'`) — a single-quoted PowerShell string expands neither `$`
/// nor a backtick, and PowerShell takes the typographic `‘’‚‛` as quotes too,
/// so those are doubled as well; elsewhere [posixQuote] (`'it'\''s.png'`).
/// Nothing is submitted, so this is not about injection: an unbalanced quote
/// would leave the prompt waiting for more, and `$x` would have the path
/// mangled the moment the user pressed Enter.
String quotePathForPrompt(String path, {required bool windows}) => quotePathFor(
  path,
  windows ? PromptQuoting.powerShell : PromptQuoting.posix,
);

/// [quotePathForPrompt] for any [PromptQuoting], cmd.exe's included.
String quotePathFor(String path, PromptQuoting style) {
  if (_bareSafe.hasMatch(path)) return path;
  switch (style) {
    case PromptQuoting.posix:
      return posixQuote(path);
    case PromptQuoting.commandPrompt:
      return '"$path"';
    case PromptQuoting.powerShell:
      final doubled = path.replaceAllMapped(
        RegExp('[\'‘’‚‛]'),
        (quote) => '${quote[0]}${quote[0]}',
      );
      return "'$doubled'";
  }
}

/// The one body behind every offer: [typed] into the session's terminal when
/// that is the face on screen, else [park]ed for its composer. [typed] is
/// asked of the pane it will be typed into, so a path can be quoted for the
/// shell that pane runs.
SessionOfferOutcome _offer(
  _Reader ref, {
  required String sessionId,
  required String Function(SnippetTarget? target) typed,
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
        snippet: _offered(typed(snippetTargetFor(terminals, state, paneId))),
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

/// Half-typed text a session's composer left when it closed, keyed by session
/// id — the peek and the tab share one. Unlike an offer ([ComposerDrafts]) it
/// is only ever put back into an **empty** box, so it never joins words
/// someone is typing in another view of the same session.
class ParkedDrafts {
  final _parked = <String, String>{};

  /// Keeps [text] for [sessionId], after any already kept that differs.
  void park(String sessionId, String text) {
    if (text.trim().isEmpty) return;
    final kept = _parked[sessionId];
    _parked[sessionId] = kept == null || kept.trim() == text.trim()
        ? text
        : '$kept\n\n$text';
  }

  /// Takes [sessionId]'s parked text, leaving nothing behind.
  String? take(String sessionId) => _parked.remove(sessionId);
}

final parkedDraftsProvider = Provider<ParkedDrafts>((_) => ParkedDrafts());

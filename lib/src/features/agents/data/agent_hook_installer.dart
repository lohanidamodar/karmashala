import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_core/util.dart';
import '../../environments/domain/environment_kind.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_hook_endpoint.dart';
import '../domain/agent_hook_transport.dart';
import '../domain/agent_status.dart';

/// Marks the hook entries Karmashala owns, so uninstall can remove exactly
/// those and leave the user's own hooks alone.
const String agentHookMarker = 'karmashala-agent-hook';

/// Markers this app wrote under names it no longer uses.
///
/// An entry is identified *only* by its marker, so renaming the app without
/// remembering the old one would strand every entry already in somebody's
/// config: the new build would not recognise it, and the old build is
/// uninstalled and cannot be asked. Nothing else in the system can find them.
///
/// These strings are literals on purpose and must survive any future rename —
/// `legacy_hook_marker_test.dart` fails if a find-and-replace rewrites them,
/// which is exactly how they would otherwise be lost.
const List<String> legacyAgentHookMarkers = <String>['chitragupta-agent-hook'];

/// Top-level config keys this app wrote under names it no longer uses.
///
/// Antigravity's `hooks.json` is a map of hook *names*, so the app's own name
/// is the key holding its whole block. A rename therefore does not move that
/// block — it abandons it, and `replaceTopLevelJsonValue` can only ever empty a
/// value, never remove it. Without this the old block would sit at the root of
/// the file for ever, belonging to nothing.
///
/// Literals on purpose; see [legacyAgentHookMarkers].
const List<String> legacyAgentHookConfigKeys = <String>['chitragupta'];

/// Installs Karmashala's callbacks into an agent's own hook configuration.
///
/// The config file is edited by **splicing** only its hook value back in
/// (`replaceTopLevelJsonValue`), so every other key keeps its original bytes —
/// agent configs can contain keys that differ only by case, which a
/// decode/encode round trip would silently collapse.
///
/// Every entry point takes the [EnvironmentKind] the config belongs to, because
/// the callback address differs per environment and there is no safe default:
/// writing a loopback URL into a WSL distribution's config installs a hook that
/// fires on every tool call and never arrives. An environment
/// [AgentHookEndpoint] cannot reach is **refused here as well as skipped by the
/// caller**, so a mistake upstream cannot put a dead URL in somebody's file.
///
/// ## Three files, and only one of them changes
///
/// An install writes, per agent and per environment:
///
///  1. the **config entry**, in the agent's own file — a constant, written once
///     and then recognised and left alone on every later launch;
///  2. the **callback script**, `karmashala-agent-hook.{cmd,sh}` in the store
///     home — also a constant, and therefore also written once;
///  3. the **endpoint file**, `karmashala-agent-hook.endpoint` beside it — how
///     to report and where, rewritten on every launch and deleted on the way
///     out ([retireEndpoint]);
///  4. for a spooling environment only, the **spool directory**,
///     `karmashala-agent-hook.spool/` beside them, which the script writes
///     payloads into and this app drains. Volatile like (3) and removed with
///     it.
///
/// **The endpoint file is also what chooses the transport.** A WSL agent cannot
/// reach any address this app binds (see [AgentHookEndpoint]), so it is given a
/// spool directory instead of a URL — and because that choice lives in (3)
/// rather than in (1), the constant in the user's config did not have to change
/// when it did.
///
/// That split is the whole design, and [hookCommand] carries the argument for
/// it: until Loop 71 the port and a per-launch token were spelled into (1),
/// which meant three CLIs' global config had to be rewritten twice per app
/// lifetime, and the race in the paragraph below had two chances a launch to
/// bite. It had already bitten on the owner's machine — zero occurrences of
/// [agentHookMarker] in the Windows `~/.claude/settings.json`, an Antigravity
/// block of `{}` — while Orca's Claude hooks, written three months earlier,
/// were still firing, for the single reason that their command never changes.
///
/// ## Every file operation here is asynchronous, and that is load-bearing
///
/// A store home is not necessarily on this machine's own disk. For
/// [EnvironmentKind.wsl] it is a `\\wsl.localhost\<distro>\home\<user>\…`
/// UNC path served by a plan9 daemon **inside** the distribution, so every
/// `exists`, every read and every rename here has a latency that belongs to
/// that distribution and not to this app — and a *synchronous* Dart file
/// operation has no timeout, so one that does not come back holds the isolate
/// for as long as it takes.
///
/// This class used to do all of it synchronously: `existsSync`,
/// `readAsStringSync`, `deleteSync`. On the owner's machine, in profile mode on
/// 2026-09-04, the start-up sweep that drives it measured **1053 ms of a 1.91 s
/// launch — 55% of it**, and none of that was CPU: the Dart isolate was at ~4%
/// of one core. It was a wait, on the thread the window is painted on.
///
/// What that costs is not only slowness. The Windows file picker runs its own
/// modal loop on the platform thread, which *is* this isolate's thread, so a
/// dialog created while the isolate is occupied is created and never shown and
/// the window goes Not Responding — measured in `core/util/file_picking.dart`
/// by occupying the isolate for 25 s. `AgentHookSpool.drain` was moved off the
/// isolate for exactly this reason and carries the share's own numbers (1 ms
/// for an `exists`, 16 ms for a `list`, 84 ms for a name that is not a
/// distribution); this was the remaining instance of the same fault.
///
/// So: nothing here is `…Sync`, the caller can put a bound on a store home that
/// does not answer (`AgentHookInstallationService.defaultStoreBudget`), and the
/// verification is untouched — [install] still reads back every file it wrote
/// and still answers about **disk** rather than about intent, because a
/// reported install that wrote nothing is worse than no install.
class AgentHookInstaller {
  const AgentHookInstaller({
    this.replace = _replaceFile,
    this.restrict = restrictToOwner,
  });

  /// How staged content is moved onto the real config. Injectable because the
  /// failure path is the guarantee: a rename cannot be made to fail on demand,
  /// and "an interrupted install leaves a config the agent can still parse" is
  /// otherwise a claim with no test behind it.
  final Future<void> Function(File staged, File destination) replace;

  /// How the endpoint file is closed to other accounts on the machine, applied
  /// to the staged file **before** the token is written into it. Injectable so
  /// a test can prove it is attempted without spawning `icacls` or `chmod`.
  final Future<bool> Function(File file, EnvironmentKind environment) restrict;

  /// Writes one hook entry per event the descriptor declares. Returns whether
  /// the config **on disk** now carries this endpoint's callback for every one
  /// of them. Throws [FormatException] if the existing config is not a JSON
  /// object, leaving it untouched.
  ///
  /// **The answer is read back, never assumed.** This used to `return true` the
  /// moment `_rewrite` came back, which made the return value a statement about
  /// intent rather than about the file — so every way a write can fail without
  /// raising was reported as a success. The owner's machine showed exactly that:
  ///
  ///   2026-09-01 11:25:53 I bootstrap: Agent hooks: 1 installed, 1 skipped.
  ///
  /// and not one `karmashala-agent-hook` anywhere under `~/.claude`, on either
  /// side of the machine, while `notifications.status` reported `0 by hook` all
  /// day. The most likely way it got there is the one this cannot prevent and
  /// must therefore report: an agent CLI rewrites its own `settings.json` from
  /// the copy it loaded at *its* start-up (`settings.json` on that machine was
  /// written at 11:39, fourteen minutes after the install), and our entries go
  /// with it. Nothing here can stop that. What it can do is stop claiming the
  /// hooks are there — a reported install that wrote nothing is worse than a
  /// reported skip, because only the skip ever gets investigated.
  ///
  /// **Idempotent to the byte, and now that is the usual case rather than a
  /// lucky one.** An event whose entry already spells the command is left
  /// alone, so the file keeps whatever formatting the user's editor gave it.
  /// The command no longer depends on the port or the token, so *every* launch
  /// after the first finds its own entry already there and writes nothing —
  /// which is the point: a rewrite that changes nothing is still a write to
  /// somebody else's config, and every write is another chance to lose the
  /// race above.
  /// Whether this agent's store exists in [storeHome] at all.
  ///
  /// The one reason [install] can answer `false` that is not a fault: there is
  /// no agent here to hook. Exposed so a caller can tell that apart from "the
  /// write did not land", which reads as a defect and is reported as one.
  Future<bool> storeIsPresent(String storeHome) =>
      Directory(storeHome).exists();

  Future<bool> install({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) async {
    final spec = descriptor.hooks;
    if (spec == null) return false;
    if (!endpoint.reaches(environment)) return false;

    // Read the config **before** writing anything beside it. The two orderings
    // below are each right on their own and would contradict each other
    // without this: the generated files have to exist before the entry that
    // names them, and nothing of ours may be left beside a config we turned out
    // not to be able to edit. A file that is not a JSON object throws here, one
    // step earlier than it used to, so a store we refuse to touch is a store we
    // wrote nothing into — not one holding a bearer token beside a
    // `settings.json` we never opened.
    await _readConfigObject(descriptor, storeHome);

    // Written **before** the config entry that names it, so no launch can leave
    // an entry pointing at a script that is not there yet. The reverse order is
    // what an interrupted install would have to survive, and a hook whose
    // command names a missing file is an error printed into the user's session.
    if (!await _writeCallbackFiles(
      descriptor: descriptor,
      storeHome: storeHome,
      endpoint: endpoint,
      environment: environment,
    )) {
      return false;
    }

    await _rewrite(descriptor, storeHome, (hooks) {
      var changed = false;
      for (final event in spec.eventStatus.keys) {
        final current = hooks[event];
        // A shape we do not understand is left exactly as it is, the way
        // [uninstall] leaves it — a hand-edited or future-shaped config is
        // still the user's, and losing a value beats nothing we install.
        if (current != null && current is! List) continue;
        final entries = current is List ? current : const <Object?>[];
        final command = hookCommand(
          descriptor: descriptor,
          event: event,
          endpoint: endpoint,
          environment: environment,
        )!;
        if (_alreadyCurrent(entries, command)) continue;
        hooks[event] = [
          ..._withoutOurs(entries),
          _entry(spec.entryStyle, command),
        ];
        changed = true;
      }
      return changed;
    });
    final events = await installedEvents(
      descriptor: descriptor,
      storeHome: storeHome,
      endpoint: endpoint,
      environment: environment,
    );
    return events.length == spec.eventStatus.length;
  }

  /// The declared events whose entry is on disk **right now**, spelling this
  /// [endpoint]'s command.
  ///
  /// Separate from [install] because the count is worth reporting on its own: a
  /// partial install — some events ours, one left alone because the user's
  /// config holds a shape we do not understand there — is a real state, and
  /// "installed: false" with no number is not enough to act on.
  ///
  /// Reads the file rather than any cached decode. A config that vanished, was
  /// truncated or stopped being JSON between the write and this call answers
  /// "none", which is the truth about what will fire.
  ///
  /// Asynchronous like everything else here, and this is the one place where
  /// that had to be argued rather than assumed: it is the **verification**, and
  /// the incident in [install]'s doc is a reported install that wrote nothing.
  /// Awaiting a read changes when the answer arrives and not what it is — the
  /// bytes are still read off disk after the write, by this method, and the
  /// count is still compared against the declared events.
  Future<Set<String>> installedEvents({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) async {
    final spec = descriptor.hooks;
    if (spec == null) return const {};
    final file = configFileFor(descriptor, storeHome)!;
    Map<String, Object?> hooks;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw.trim().isEmpty ? '{}' : raw);
      if (decoded is! Map<String, Object?>) return const {};
      final current = decoded[spec.configKey];
      hooks = current is Map<String, Object?> ? current : const {};
    } on Object {
      return const {};
    }

    final found = <String>{};
    for (final event in spec.eventStatus.keys) {
      final entries = hooks[event];
      if (entries is! List) continue;
      final command = hookCommand(
        descriptor: descriptor,
        event: event,
        endpoint: endpoint,
        environment: environment,
      );
      if (command == null) continue;
      if (_alreadyCurrent(entries, command)) found.add(event);
    }
    return found;
  }

  /// Removes the entries this app installed. Returns whether anything changed.
  Future<bool> uninstall({
    required AgentDescriptor descriptor,
    required String storeHome,
  }) async {
    final spec = descriptor.hooks;
    if (spec == null) return false;

    var changed = false;
    await _rewrite(descriptor, storeHome, (hooks) {
      for (final event in hooks.keys.toList()) {
        final current = hooks[event];
        // Not a list: not a shape this app ever wrote, so there is nothing of
        // ours in it and nothing to decide. Casting it would throw on a config
        // we are only passing through.
        if (current is! List) continue;
        final kept = _withoutOurs(current);
        if (kept.length == current.length) continue;
        changed = true;
        if (kept.isEmpty) {
          hooks.remove(event);
        } else {
          hooks[event] = kept;
        }
      }
      return changed;
    });
    // The script and the endpoint file go with them. The endpoint file is the
    // only file in this feature that holds a bearer token and a port, so
    // leaving it behind would outlive both the address it names and the app
    // that could answer on it — the same argument [uninstall] exists for, one
    // file further along. Removed whichever way the config edit went: a config
    // that never carried our entry can still be sitting beside files an earlier
    // run wrote.
    if (await _removeGeneratedFiles(descriptor, storeHome)) changed = true;
    return changed;
  }

  /// Deletes the endpoint file and leaves everything else in place.
  ///
  /// What the app does **on the way out**, in place of a full [uninstall].
  ///
  /// The config entry and the script are now constants — the same bytes on
  /// every launch, on every machine, for the life of the install — so there is
  /// nothing in either of them that goes stale, and taking them out on quit
  /// only to put identical bytes back on the next start is what put us in the
  /// documented race in the first place (see the class doc). What genuinely
  /// dies with the process is the **address and the token**, and those live
  /// here alone.
  ///
  /// With the file gone the installed script costs the agent one
  /// `if not exist` / `[ -f ]` and exits zero. That is strictly cheaper than
  /// what a stale entry costs today — a `curl -m 2` at a port nothing owns, on
  /// every tool call — and it is why leaving the entry behind is now safe.
  ///
  /// Returns whether a file was removed.
  Future<bool> retireEndpoint({
    required AgentDescriptor descriptor,
    required String storeHome,
  }) async {
    if (descriptor.hooks == null) return false;
    var removed = false;
    final file = _endpointFile(descriptor, storeHome);
    if (file != null && await file.exists()) {
      try {
        await file.delete();
        removed = true;
      } on FileSystemException {
        // Someone else's directory. The script fails closed on a token it
        // cannot authenticate with anyway, so this is hygiene rather than a
        // hole.
      }
    }
    // And the staging file beside it, which is what a *previous* quit left when
    // it cut this sweep's counterpart off mid-write. The soak found those
    // accumulating in the agents' store homes, one per interrupted launch.
    if (file != null) await _removeStaged(File('${file.path}.karmashala-tmp'));
    // The spool goes with it, and for the same reason: what it holds is this
    // launch's undelivered payloads, and there is no launch any more. Leaving
    // it would also leave the script a directory to keep writing into if the
    // endpoint file ever came back without one.
    final spool = spoolDirectoryFor(descriptor, storeHome);
    if (spool != null && await spool.exists()) {
      try {
        await spool.delete(recursive: true);
        removed = true;
      } on FileSystemException {
        // Same answer: the script exits zero on a directory it cannot see, and
        // a directory it can see holds nothing but its own payloads.
      }
    }
    return removed;
  }

  /// The command line an agent runs for [event]: run the generated callback
  /// script, with the event as its one argument. `null` when nothing this app
  /// binds is reachable from [environment], or when the agent declares no store
  /// to keep the script in.
  ///
  /// **Every part of this string is a constant**, and that is the whole point
  /// of the change that produced it. Until Loop 71 the address and a per-launch
  /// bearer token were spelled *inline*:
  ///
  /// ```
  /// curl -s -m 2 -X POST -H "Authorization: Bearer <token>" \
  ///   --data-binary @- "http://127.0.0.1:<port>/agent-hook?…" || true
  /// ```
  ///
  /// `LauncherControlServer.start()` mints a fresh hook token on every run, so
  /// that string differed on every launch — which meant three CLIs' **global**
  /// config files had to be rewritten twice per app lifetime, and every rewrite
  /// was another chance to lose the race this class documents: an agent CLI
  /// rewrites its own `settings.json` from the copy it loaded at *its* start-up
  /// and our entry goes with it. On the owner's machine that race had already
  /// been lost — `karmashala-agent-hook` appeared in the Windows
  /// `~/.claude/settings.json` **zero** times, and the Antigravity block was
  /// `{}`, while Orca's Claude hooks, written on 22 June, were still firing
  /// three months later for one reason: *their command string never changes.*
  ///
  /// So the volatile half moved one level of indirection out, into an endpoint
  /// file the script reads **when the hook fires** ([_endpointFileName]). That
  /// is Orca's shape — all 17 of its hook scripts open by sourcing
  /// `ORCA_AGENT_HOOK_ENDPOINT` — adapted in the one way that matters here:
  /// ours is a **fixed path**, not an environment variable. An environment
  /// variable has to be set in the agent's own environment, and we do not own
  /// that environment for any of the three. Their hooks live in *global*
  /// config and fire for a CLI the user started in their own terminal, in a
  /// process tree this app never touched; Codex additionally runs each hook
  /// through the session's own shell with `-lc`
  /// (`hooks/src/engine/command_runner.rs`), a login shell that reads the
  /// user's profile and can replace anything it inherited. Orca reaches the
  /// same conclusion from the other end — `command-code-hook.cmd` carries a
  /// `:sourceEndpointByPort` fallback that goes looking on disk *"for hook
  /// processes that inherit no environment"*.
  ///
  /// Codex was already half-way here for a different reason: it hashes the
  /// entry to decide trust (see [AgentHookSpec.trustsCommandByHash]), so its
  /// command had to be fixed or the grant would be revoked every launch. That
  /// requirement is now met for all three agents by construction rather than
  /// for one agent as a special case.
  String? hookCommand({
    required AgentDescriptor descriptor,
    required String event,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) {
    // The reachability gate the URL used to provide. An environment nothing
    // this app binds can serve gets no command at all, so a mistake upstream
    // cannot put a hook in a config it could never call back from.
    if (!endpoint.reaches(environment)) return null;
    if (descriptor.hooks == null) return null;
    return _scriptCommand(
      descriptor: descriptor,
      event: event,
      environment: environment,
    );
  }

  /// The base name of the generated callback script, extension excluded.
  ///
  /// It **is** [agentHookMarker], and that is load-bearing rather than tidy:
  /// an installed entry is recognised as ours only by the marker appearing in
  /// its command string ([_isOurs]), and for a fixed-command agent the command
  /// is nothing but this path and an event name. Naming the file anything else
  /// would strand every entry in somebody's config the moment the app was
  /// uninstalled, exactly as [legacyAgentHookMarkers] describes.
  static const String _scriptBaseName = agentHookMarker;

  /// The file the generated script reads its address and token out of, every
  /// time a hook fires.
  ///
  /// One name for both platforms, because one store home is only ever reached
  /// from one side of the machine: `CliStoreLocator` builds a Windows store
  /// under `%USERPROFILE%` and a WSL store under a `\\wsl.localhost` UNC, which
  /// are different directories. The *contents* are written with the line
  /// endings that environment's reader expects — `for /f` is given CRLF, `read`
  /// is given LF — and only the script beside it ever opens it.
  ///
  /// It sits in the store home rather than in this app's own data directory on
  /// purpose. A WSL agent's `sh` cannot open a Windows path, and an SSH agent
  /// cannot open a local one at all; the store home is the single place both
  /// this app and the agent can name, which is the same reason
  /// [_scriptCommand] spells the home directory as a variable.
  static const String _endpointFileName = '$_scriptBaseName.endpoint';

  /// The directory a spooling agent drops its payloads into, beside the script
  /// and the endpoint file that name it.
  ///
  /// Only ever written by an agent inside a WSL distribution, and only ever
  /// read from the Windows side over `\\wsl.localhost` — the one place both
  /// sides can name the same bytes, which is the same argument
  /// [_endpointFileName] is kept in the store home for.
  ///
  /// Volatile, like the endpoint file: the payloads in it belong to a launch,
  /// so [retireEndpoint] takes the whole directory with it. What survives an
  /// unclean exit is bounded by the script, which stops writing once the
  /// directory holds 2000 files, and is harmless when it is finally drained
  /// because each payload is timed by its own file's mtime rather than by when
  /// this app got round to reading it.
  static const String _spoolDirectoryName = '$_scriptBaseName.spool';

  /// Where [descriptor]'s spooled payloads land under [storeHome], as **this
  /// app** sees it — the Windows-side `\\wsl.localhost\…` spelling for a WSL
  /// store. `null` for an agent with no store of its own.
  ///
  /// Public because the drainer needs it and must not re-derive the name: a
  /// second spelling of a generated path is how an uninstall comes to leave
  /// something behind.
  Directory? spoolDirectoryFor(AgentDescriptor descriptor, String storeHome) =>
      descriptor.store == null
      ? null
      : Directory(p.join(storeHome, _spoolDirectoryName));

  /// The generated script's file name in [environment].
  ///
  /// Two spellings because the interpreter differs, not because the work does:
  /// a `.cmd` is what `cmd.exe` will run, and a `.sh` is what a distribution's
  /// `sh` will. Both are named explicitly by [_scriptCommand], so neither
  /// relies on an execute bit — which a file written onto a
  /// `\\wsl.localhost` share does not reliably carry anyway.
  static String _scriptFileName(EnvironmentKind environment) =>
      environment == EnvironmentKind.windowsNative
      ? '$_scriptBaseName.cmd'
      : '$_scriptBaseName.sh';

  /// The command an agent runs for [event] — the generated script, named
  /// through the same home-directory variable the store locator itself
  /// resolved, and the event as its one argument.
  ///
  /// **Every part of this string is a constant**, for every agent. Codex is
  /// where the requirement is *enforced* ([AgentHookSpec.trustsCommandByHash]:
  /// the hash it trusts covers this text, so anything that changed between
  /// launches would revoke the user's grant on every start), and it is worth
  /// having for the other two as well — an entry that never changes is an entry
  /// that can be written once and then left alone, which is what stops us
  /// racing the CLI that owns the file.
  ///
  /// The home directory is named as `%USERPROFILE%` / `$HOME` rather than
  /// resolved here, and that is what makes one string correct in every
  /// reachable environment. `CliStoreLocator` builds the store home from
  /// exactly those two variables — `USERPROFILE` where the environment uses
  /// Windows paths, `HOME` everywhere else — so the path the agent expands at
  /// run time is the path this installer wrote to, by construction. It also
  /// settles WSL, where the two disagree about spelling and not about place:
  /// the app reaches that store as `\\wsl.localhost\<distro>\home\<user>\…`
  /// and the agent inside the distribution reaches the same bytes as
  /// `$HOME/…`. Writing the app's own view into the command would install a
  /// path no process inside the distribution can open.
  ///
  /// **Both forms survive the shell the agent happens to use, which is not one
  /// shell.** Codex hands the string to the session's own detected shell, and
  /// only falls back to a fixed one when it has none
  /// (`hooks/src/engine/command_runner.rs`, `default_shell_command`:
  /// `%COMSPEC%` or `cmd.exe` with `/C` on Windows, `$SHELL` or `/bin/sh` with
  /// `-lc` elsewhere). On Windows the detected shell is commonly PowerShell,
  /// where `%USERPROFILE%` does not expand and a quoted path is a string
  /// expression rather than a command — so naming `cmd.exe` explicitly is what
  /// makes the same text work under `cmd`, Windows PowerShell and `pwsh`
  /// alike: every one of them passes the quoted argument through unexpanded,
  /// and the `cmd` we name does the expanding. On POSIX, `sh` is named for the
  /// matching reason — a file written across a `\\wsl.localhost` share lands
  /// mode 644, so it must be interpreted rather than executed.
  static String? _scriptCommand({
    required AgentDescriptor descriptor,
    required String event,
    required EnvironmentKind environment,
  }) {
    final store = descriptor.store;
    // A stable command needs a directory of its own to keep the script and the
    // endpoint file in, and the store home is the only one this app knows how
    // to name from inside the agent's environment. Without it there is nowhere
    // to put either file, so such an agent gets no hook rather than an inline
    // command that would change on every launch — which is the bug, not the
    // fallback.
    if (store == null) return null;
    final file = _scriptFileName(environment);
    return switch (environment) {
      EnvironmentKind.windowsNative =>
        'cmd.exe /c "%USERPROFILE%\\'
            '${store.homeDirectoryName.replaceAll('/', '\\')}\\$file" $event',
      EnvironmentKind.localPosix || EnvironmentKind.wsl =>
        'sh "\$HOME/${store.homeDirectoryName}/$file" $event',
      // Never reached: [AgentHookEndpoint.reaches] is false for SSH, so no
      // command is ever asked for. Spelled out rather than defaulted so a new
      // environment kind is a compile error here instead of a silent guess.
      EnvironmentKind.ssh => null,
    };
  }

  /// Writes the two files [_scriptCommand] depends on — the constant script and
  /// the endpoint file it reads — and reports whether both are on disk spelling
  /// what this run intends.
  ///
  /// The order is the same argument as [install]'s: the endpoint file is
  /// written **after** the script, because a script with no endpoint file exits
  /// zero and costs the agent nothing, while an endpoint file with no script is
  /// a token sitting on disk that nothing will ever delete.
  ///
  /// **The endpoint file is the one place the bearer token lives in bytes of
  /// our own**, and after this change it is the *only* place: the config entry
  /// no longer carries it. Same token, same lifetime and the same status-only
  /// privilege the inline command had — separate from the `/rpc` credential and
  /// documented as public to anything running as this user
  /// (`LauncherControlServer`'s threat model). Two properties improve:
  /// [retireEndpoint] deletes it on the way out, so it does not outlive the app
  /// that minted it, and it is written under an owner-only permission where the
  /// platform lets us assert one ([restrict]).
  ///
  /// Nothing here is logged. The URL and the file body both carry the token, so
  /// neither may reach a log line — the only thing this reports upward is a
  /// bool.
  Future<bool> _writeCallbackFiles({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) async {
    final transport = endpoint.transportFor(environment);
    if (transport == null) return false;
    final script = _callbackScriptFile(descriptor, storeHome, environment);
    final endpointFile = _endpointFile(descriptor, storeHome);
    if (script == null || endpointFile == null) return false;

    if (!await _writeIfChanged(
      script,
      storeHome,
      environment == EnvironmentKind.windowsNative
          ? _windowsScript
          : _posixScript,
    )) {
      return false;
    }

    switch (transport) {
      case AgentHookHttpTransport():
        final uri = endpoint.uriFor(
          agentId: descriptor.id,
          event: '',
          environment: environment,
        );
        if (uri == null) return false;
        // The address, with the event left to the script's own argument. Built
        // by hand rather than through `Uri.replace` because the `$event` /
        // `%~1` that stands in for it is not a legal query value and would be
        // escaped.
        final base =
            '${uri.origin}${uri.path}'
            '?agent=${Uri.encodeQueryComponent(descriptor.id)}'
            '&marker=${Uri.encodeQueryComponent(agentHookMarker)}'
            '&event=';
        return _writeIfChanged(
          endpointFile,
          storeHome,
          _httpEndpointFileContents(
            base: base,
            token: transport.token,
            newline: environment == EnvironmentKind.windowsNative
                ? '\r\n'
                : '\n',
          ),
          harden: (staged) => restrict(staged, environment),
        );
      case AgentHookSpoolTransport():
        // The directory the script drops payloads into, made **before** the
        // endpoint file that names it — the same ordering argument as
        // everything else here: the script exits zero on a directory that is
        // not there, so a half-finished install costs the agent nothing.
        final spool = spoolDirectoryFor(descriptor, storeHome);
        if (spool == null) return false;
        try {
          if (!await spool.exists()) await spool.create(recursive: true);
        } on FileSystemException {
          return false;
        }
        // No `harden`: there is no credential in this file. See
        // [AgentHookSpoolTransport] for why the token is dropped rather than
        // carried for symmetry.
        return _writeIfChanged(
          endpointFile,
          storeHome,
          _spoolEndpointFileContents(
            agentId: descriptor.id,
            spool: _spoolDirectoryName,
          ),
        );
    }
  }

  /// Writes [contents] to [file] unless it already holds exactly that, and
  /// reports whether the bytes on disk are now [contents].
  ///
  /// Idempotent to the byte, exactly as the config write is. That now matters
  /// for the script rather than being a nicety: its text is a constant, so
  /// after the first install every later launch reads it, finds it identical
  /// and writes nothing at all.
  Future<bool> _writeIfChanged(
    File file,
    String storeHome,
    String contents, {
    Future<void> Function(File staged)? harden,
  }) async {
    if (await file.exists()) {
      try {
        if (await file.readAsString() == contents) return true;
      } on FileSystemException {
        // Unreadable but present — rewritten below rather than trusted.
      }
    }
    if (!await Directory(storeHome).exists()) {
      // The agent is not installed in this environment, so there is nothing to
      // hook. Returning rather than writing, because both other outcomes are
      // wrong: the callback script lives *inside* the store home, so the
      // create-parent below could not help it — the guard read "create the
      // store home if the store home exists" — and `_writeAtomically` then
      // threw `PathNotFoundException` on every launch. A Mac with the
      // Antigravity IDE (`~/.gemini/antigravity`) but not its CLI
      // (`~/.gemini/antigravity-cli`) logged that warning at every start.
      // Creating the directory instead would leave an empty agent home in
      // somebody's `~` for a tool they never installed.
      return false;
    }
    final parent = file.parent;
    if (!await parent.exists()) {
      // The config need not live in the store home — `~/.gemini/config` sits
      // beside `~/.gemini/antigravity-cli` — so its directory can still be one
      // the CLI has not created yet.
      await parent.create(recursive: true);
    }
    await _writeAtomically(file, contents, harden: harden);
    try {
      return await file.readAsString() == contents;
    } on FileSystemException {
      return false;
    }
  }

  /// The endpoint file's body: the address and the token, and nothing else.
  ///
  /// `key=value`, one per line, with `#` comments — the shape both readers can
  /// parse without spawning anything. `sh` walks it with `case`, `cmd.exe` with
  /// a `for /f "eol=# tokens=1,* delims=="`, so neither pays a process for the
  /// read. Orca executes its equivalent instead (`endpoint.cmd`, `call`ed;
  /// `endpoint.env`, sourced), which is cheaper still and makes the file
  /// arbitrary code in somebody's home directory. Parsing it costs a few lines
  /// of shell and buys the property that a corrupted or half-written file can
  /// only ever produce an empty `url`, which the script treats as "do nothing".
  ///
  /// [newline] is the environment's, not this process's: `for /f` is handed a
  /// CRLF file and `read` an LF one, so neither reader has to strip anything.
  static String _httpEndpointFileContents({
    required String base,
    required String token,
    required String newline,
  }) => <String>[
    '# Karmashala agent status callback endpoint.',
    '#',
    '# Generated on every launch and deleted when the app exits. The script',
    '# beside this file reads it each time a hook fires, which is what lets the',
    '# command in your agent\'s own config stay a constant. Editing this file',
    '# changes nothing past the current launch.',
    'url=$base',
    'token=$token',
  ].map((line) => '$line$newline').join();

  /// The endpoint file for [AgentHookSpoolTransport]: a directory to write
  /// into, the agent's own id, and **no credential**.
  ///
  /// The two keys the HTTP form carries are both absent, and their absence is
  /// what the script reads to choose this transport. `agent=` is here because
  /// the query string that used to carry it is gone: a spooled payload has to
  /// name its own agent, and this file is the only constant beside the script
  /// that knows which agent's store it sits in.
  ///
  /// Always LF. Only a distribution's `sh` ever reads this form — Windows and
  /// the local POSIX host both share a loopback with this process and take the
  /// HTTP one.
  static String _spoolEndpointFileContents({
    required String agentId,
    required String spool,
  }) => <String>[
    '# Karmashala agent status callback endpoint.',
    '#',
    '# Generated on every launch and deleted when the app exits. The script',
    '# beside this file reads it each time a hook fires, which is what lets the',
    '# command in your agent\'s own config stay a constant. Editing this file',
    '# changes nothing past the current launch.',
    '#',
    '# There is no token here and that is deliberate: this environment reports',
    '# by writing a file that Karmashala reads over the WSL share, so nothing',
    '# is sent over a network and there is no listener for an impostor to bind.',
    'spool=$spool',
    'agent=$agentId',
  ].map((line) => '$line\n').join();

  /// The `sh` body. `$1` is the hook event name, supplied by the command.
  ///
  /// **A constant.** No port, no token, no agent id: everything that changes
  /// between launches is read out of the endpoint file at fire time. See
  /// [hookCommand] for why that is the whole point.
  ///
  /// The endpoint file is named relative to `$0` rather than spelled out, so
  /// the script and the file it reads cannot end up disagreeing about a path.
  /// `${0%/*}` is a parameter expansion, not `dirname` — this runs on every
  /// hook of every agent, and a process spawned to compute a directory would be
  /// a process too many.
  ///
  /// **Fail closed, and specifically at 401.** The endpoint file survives an
  /// unclean exit, so this has to assume the port it names may belong to
  /// somebody else by now — the hazard `AgentHookInstallationService` documents
  /// as *"hands its bearer token to whatever binds that port next"*. So nothing
  /// is sent until an **unauthenticated** probe comes back `401`: no token, no
  /// payload, just a status line. Any HTTP status line coming back proves the
  /// door, and a `401` proves it as well as a `200` does, so the probe carries
  /// no credential — and this one is stricter on purpose. A squatter proves
  /// nothing by accepting a connection; ours is the only listener on that port
  /// that answers `401` to a `GET /agent-hook` with no credential, because that
  /// is what `LauncherControlServer._handleAgentHook` does before it looks at
  /// anything else. A dead port prints `000`, a stranger prints whatever it
  /// serves, and both mean the same thing here: exit without sending.
  ///
  /// What survives that guard is a process deliberately impersonating this app
  /// on this machine, and the threat model already concedes that case — *"a
  /// process running as this user is inside the boundary, by construction"*.
  ///
  /// **Nothing this runs may reach the agent's stdout.** A hook that can decide
  /// something reads its own stdout for that decision — Codex's
  /// `PermissionRequest` looks for a `decision` there — and the endpoint answers
  /// every callback with `{"ok":true,"status":"…"}`. `-o /dev/null` throws it
  /// away before it can be read as a verdict on somebody's tool call. The
  /// precedent is measured, not theoretical: an empty `{}` from an Antigravity
  /// `PreToolUse` hook produced *"tool call denied by pre-tool hook"* on a live
  /// run. The probe's body is discarded for the same reason; only its status
  /// code is read, into a shell variable.
  ///
  /// **And the exit status is forced, not merely tidied.** Codex reads **exit
  /// code 2 with non-empty stderr as a denial**, and turns the stderr text into
  /// the rejection the user is shown (`hooks/src/events/permission_request.rs`,
  /// the exit-2 arm of `parse_completed`). `curl` exits 2 on an option it
  /// cannot parse — a truncated or half-written script is enough — so a wrapper
  /// that let its own status through could start refusing the user's tool calls
  /// and blaming curl for it. Every other non-zero exit, and a timeout, are
  /// already neutral; 2 is the one that is not, and `exit 0` closes it.
  /// **Two transports, one constant script, and the endpoint file picks.**
  /// `spool=` selects [AgentHookSpoolTransport] and `url=`/`token=` select
  /// [AgentHookHttpTransport]; the script does not know which environment it is
  /// in and does not need to. That is what keeps the *command* in the user's
  /// config a constant even though the transport for their WSL agent changed:
  /// the entry names this script, the script asks the file, and the file is the
  /// only thing a launch rewrites.
  ///
  /// **And both branches stop reading at [kAgentHookPayloadLimitBytes]**, which
  /// is the receiver's own cap. `head -c` replaces the `cat` in the spool
  /// branch — the same one fork, so the bound is free there — and stands in
  /// front of `curl` in the HTTP branch, which is one more. The payload is the
  /// agent's event and a `PostToolUse` can carry a whole file's contents, so
  /// this is what stops a runaway one being read into memory, written to a
  /// spool file and posted, only to be refused at the far end.
  ///
  /// The spool branch is three syscalls and two forks and cannot fail slowly:
  /// measured at **3.6 ms per hook** inside the owner's distribution, against
  /// 2008 ms for the `curl` branch on the same machine, where the probe times
  /// out and the payload is then dropped. The event name is saved into `event`
  /// **before** anything else, because the cap below re-uses `$@`.
  static const String _posixScript =
      '#!/bin/sh\n'
      '# Karmashala agent status callback. Generated; edits will not survive.\n'
      '#\n'
      '# This file is a constant: where to report and how live in the endpoint\n'
      '# file beside it and are read here, every time a hook fires. A file\n'
      '# naming a spool directory is written to; one naming a url is posted to,\n'
      '# and then only once an unauthenticated probe proves the port still\n'
      '# belongs to Karmashala.\n'
      'event="\$1"\n'
      'here="\${0%/*}"\n'
      'endpoint="\$here/$_endpointFileName"\n'
      '[ -f "\$endpoint" ] || exit 0\n'
      "url=''\n"
      "token=''\n"
      "spool=''\n"
      "agent=''\n"
      'while IFS= read -r line; do\n'
      '  case "\$line" in\n'
      '    url=*) url="\${line#url=}" ;;\n'
      '    token=*) token="\${line#token=}" ;;\n'
      '    spool=*) spool="\${line#spool=}" ;;\n'
      '    agent=*) agent="\${line#agent=}" ;;\n'
      '  esac\n'
      'done < "\$endpoint"\n'
      'if [ -n "\$spool" ]; then\n'
      '  dir="\$here/\$spool"\n'
      '  [ -d "\$dir" ] || exit 0\n'
      '  set -- "\$dir"/*.json\n'
      '  [ "\$#" -lt 2000 ] || exit 0\n'
      '  n=0\n'
      '  while [ -e "\$dir/\$\$-\$n.json" ] || [ -e "\$dir/\$\$-\$n.part" ]; '
      'do\n'
      '    n=\$((n+1))\n'
      '    [ "\$n" -lt 64 ] || exit 0\n'
      '  done\n'
      "  { printf 'agent=%s\\nevent=%s\\n\\n' \"\$agent\" \"\$event\"; "
      'head -c $kAgentHookPayloadLimitBytes; } '
      '> "\$dir/\$\$-\$n.part" 2>/dev/null || exit 0\n'
      '  mv -f "\$dir/\$\$-\$n.part" "\$dir/\$\$-\$n.json" 2>/dev/null\n'
      '  exit 0\n'
      'fi\n'
      '[ -n "\$url" ] && [ -n "\$token" ] || exit 0\n'
      "code=\$(curl -s -o /dev/null -m 2 -w '%{http_code}' \"\$url\" "
      '2>/dev/null)\n'
      '[ "\$code" = "401" ] || exit 0\n'
      'head -c $kAgentHookPayloadLimitBytes '
      '| curl -s -o /dev/null -m 2 -X POST \\\n'
      '  -H "Authorization: Bearer \$token" \\\n'
      '  --data-binary @- \\\n'
      '  "\$url\$event" 2>/dev/null\n'
      'exit 0\n';

  /// The `cmd.exe` body. `%~1` is the hook event name, unquoted.
  ///
  /// CRLF throughout: a batch file with bare newlines is read by some Windows
  /// shells and not others, and this one is written from a Dart process whose
  /// default is `\n`. See [_posixScript] for the guard, the discarded output
  /// and the forced exit status — this is the same script in the other shell.
  ///
  /// Two spellings differ for reasons rather than taste. `%~dp0` is `cmd`'s
  /// `${0%/*}` and already carries its trailing separator. And the probe's
  /// status code comes back through a temporary file read with `set /p`, which
  /// is a builtin: the obvious `for /f %%c in ('curl …')` would spawn a second
  /// `cmd.exe` to run the pipeline, on every hook of every tool call, which is
  /// the one cost this design cannot afford. The file goes to `%TEMP%` and is
  /// deleted immediately; a `%RANDOM%` in its name keeps two hooks firing at
  /// once out of each other's way.
  ///
  /// ### The payload bound, and why it is spelled so differently here
  ///
  /// `cmd` has no `head -c`. It has no byte-exact way to copy a stream at all:
  /// `more` re-encodes and expands tabs (measured — 118 bytes of JSON came back
  /// as 61 of mojibake), `findstr` and `sort` are line-oriented, and `copy con`
  /// does not read a redirected handle. So the bound is applied by **measuring
  /// rather than cutting**: `curl -T -` spills stdin into `%TEMP%` byte for
  /// byte, `%%~zI` reads its size, and the POST happens only if it is within
  /// [kAgentHookPayloadLimitBytes]. A payload over the bound is dropped, which
  /// is what the receiver would do with it anyway — and a truncated JSON body
  /// is not a payload either, so the two ends agree on the outcome.
  ///
  /// It costs one more `curl` on the path that actually posts, and none on the
  /// path that does not: the spill sits *after* the 401 probe, so a dead port
  /// still costs exactly one process.
  ///
  /// `enabledelayedexpansion` is for one line — `%20` cannot be written into a
  /// `%VAR:from=to%` replacement, because `cmd` reads `%2` as an argument — and
  /// a space in `%TEMP%` (`C:\Users\John Doe\…`) is otherwise enough to make
  /// `curl` refuse the URL. It is safe here because every value this script
  /// holds is one we generated: a base64url token and a URL whose query
  /// components are encoded, neither of which can contain a `!`.
  static const String _windowsScript =
      '@echo off\r\n'
      'rem Karmashala agent status callback. Generated; edits will not '
      'survive.\r\n'
      'rem\r\n'
      'rem This file is a constant: the address and the token live in the\r\n'
      'rem endpoint file beside it and are read here, every time a hook '
      'fires.\r\n'
      'rem Nothing is sent until an unauthenticated probe proves the port\r\n'
      'rem still belongs to Karmashala.\r\n'
      'setlocal enabledelayedexpansion\r\n'
      'set "KS_ENDPOINT=%~dp0$_endpointFileName"\r\n'
      'if not exist "%KS_ENDPOINT%" exit /b 0\r\n'
      'set "KS_URL="\r\n'
      'set "KS_TOKEN="\r\n'
      'for /f "usebackq eol=# tokens=1,* delims==" %%A in '
      '("%KS_ENDPOINT%") do (\r\n'
      '  if "%%A"=="url" set "KS_URL=%%B"\r\n'
      '  if "%%A"=="token" set "KS_TOKEN=%%B"\r\n'
      ')\r\n'
      'if not defined KS_URL exit /b 0\r\n'
      'if not defined KS_TOKEN exit /b 0\r\n'
      'set "KS_PROBE=%TEMP%\\$_scriptBaseName.%RANDOM%.code"\r\n'
      'set "KS_CODE="\r\n'
      'curl -s -o NUL -m 2 -w "%%{http_code}" "%KS_URL%" > "%KS_PROBE%" '
      '2>NUL\r\n'
      'set /p KS_CODE=<"%KS_PROBE%"\r\n'
      'del "%KS_PROBE%" >NUL 2>NUL\r\n'
      'if not "%KS_CODE%"=="401" exit /b 0\r\n'
      'set "KS_BODY=%TEMP%\\$_scriptBaseName.%RANDOM%.body"\r\n'
      'set "KS_BODYURL=!KS_BODY:\\=/!"\r\n'
      'set "KS_BODYURL=!KS_BODYURL: =%%20!"\r\n'
      'curl -s -T - "file:///!KS_BODYURL!" 2>NUL\r\n'
      'set "KS_SIZE="\r\n'
      'for %%I in ("%KS_BODY%") do set "KS_SIZE=%%~zI"\r\n'
      'if defined KS_SIZE if !KS_SIZE! LEQ $kAgentHookPayloadLimitBytes '
      'curl -s -o NUL -m 2 -X POST '
      '-H "Authorization: Bearer %KS_TOKEN%" '
      '--data-binary @"%KS_BODY%" "%KS_URL%%~1" 2>NUL\r\n'
      'del "%KS_BODY%" >NUL 2>NUL\r\n'
      'exit /b 0\r\n';

  /// Deletes every generated file under [storeHome] — both spellings of the
  /// script, and the endpoint file. Returns whether anything was removed.
  ///
  /// Both script spellings, not the one this environment would write: a store
  /// can be reached from more than one side of a machine, and an uninstall that
  /// only swept its own platform's extension would leave the other behind for
  /// ever.
  Future<bool> _removeGeneratedFiles(
    AgentDescriptor descriptor,
    String storeHome,
  ) async {
    var removed = await retireEndpoint(
      descriptor: descriptor,
      storeHome: storeHome,
    );
    for (final environment in EnvironmentKind.values) {
      final file = _callbackScriptFile(descriptor, storeHome, environment);
      if (file == null || !await file.exists()) continue;
      try {
        await file.delete();
        removed = true;
      } on FileSystemException {
        // Someone else's directory, and the config entry is already gone — a
        // script nothing names costs the agent nothing.
      }
    }
    return removed;
  }

  /// Where the generated script sits **as this app sees it**: in the store
  /// home, which is the same directory [_scriptCommand] names from inside the
  /// agent's own environment.
  ///
  /// The two agree by construction rather than by luck.
  /// `CliStoreLocator._homesUnder` builds every store home as
  /// `<home>/<store.homeDirectoryName>` and nothing else, from `%USERPROFILE%`
  /// where the environment uses Windows paths and `$HOME` everywhere else — the
  /// exact two variables the command spells. **The agent's config file has
  /// nothing to do with it**: Antigravity keeps its data in
  /// `~/.gemini/antigravity-cli` and reads `~/.gemini/config/hooks.json`, and
  /// an earlier version of this refused to write a script at all in that case,
  /// which is why Antigravity kept the inline command long after Codex stopped
  /// needing one.
  ///
  /// `null` only for an agent that declares no store, which has nowhere of its
  /// own to keep a file — and therefore no way to be given a stable command.
  File? _callbackScriptFile(
    AgentDescriptor descriptor,
    String storeHome,
    EnvironmentKind environment,
  ) => descriptor.store == null
      ? null
      : File(p.join(storeHome, _scriptFileName(environment)));

  /// Where the endpoint file sits, as this app sees it. See
  /// [_callbackScriptFile] for why the store home is the right directory.
  File? _endpointFile(AgentDescriptor descriptor, String storeHome) =>
      descriptor.store == null
      ? null
      : File(p.join(storeHome, _endpointFileName));

  /// The config's raw text and its decoded root object, or a throw.
  ///
  /// Called twice per install — once as [install]'s pre-flight and once inside
  /// [_rewrite] — and that is deliberate rather than sloppy. The file is small,
  /// it is read at start-up off the launch path, and re-reading it means the
  /// splice works on the bytes that are there *now* rather than on a copy taken
  /// before this app wrote two files beside it.
  ///
  /// A missing or empty file reads as `{}`: an agent installed but never run
  /// has no config yet, and refusing to create one would be refusing to install
  /// for the case the feature is most useful in.
  Future<(String, Map<String, Object?>)> _readConfigObject(
    AgentDescriptor descriptor,
    String storeHome,
  ) async {
    final file = configFileFor(descriptor, storeHome)!;
    final raw = await file.exists() ? await file.readAsString() : '{}';
    final trimmed = raw.trim().isEmpty ? '{}' : raw;
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Agent config root is not a JSON object');
    }
    return (trimmed, decoded);
  }

  /// Reads the config, hands its hook map to [edit], and splices the result
  /// back if [edit] reports a change.
  Future<bool> _rewrite(
    AgentDescriptor descriptor,
    String storeHome,
    bool Function(Map<String, Object?> hooks) edit,
  ) async {
    final spec = descriptor.hooks!;
    final file = configFileFor(descriptor, storeHome)!;
    final (trimmed, decoded) = await _readConfigObject(
      descriptor,
      storeHome,
    );
    final current = decoded[spec.configKey];
    final hooks = current is Map<String, Object?>
        ? Map<String, Object?>.from(current)
        : <String, Object?>{};

    // A block we left behind under an older name of this app. Dropped whether
    // or not [edit] changes anything, because it is ours and nothing else will
    // ever recognise it.
    final abandoned = legacyAgentHookConfigKeys
        .where((key) => key != spec.configKey && decoded.containsKey(key))
        .toList();

    if (!edit(hooks) && abandoned.isEmpty) return false;

    // The config need not sit in the store home, so its directory can be one
    // the CLI has not created yet — `~/.gemini/config` beside
    // `~/.gemini/antigravity-cli`. Created only when the **store** is really
    // there, so a machine without this agent installed never gets an empty
    // config directory in its home from us.
    final parent = file.parent;
    if (!await parent.exists() && await Directory(storeHome).exists()) {
      await parent.create(recursive: true);
    }

    var updated = replaceTopLevelJsonValue(
      trimmed,
      spec.configKey,
      jsonEncode(hooks),
    );
    for (final key in abandoned) {
      updated = removeTopLevelJsonKey(updated, key);
    }
    await _writeAtomically(file, updated);
    return true;
  }

  /// Stages [contents] beside [file] and moves it into place.
  ///
  /// A plain `writeAsString` truncates the config first, so a process killed
  /// mid-write leaves an agent that will not start — and this now writes across
  /// a `\\wsl.localhost` share as well as to local disk, where a write is
  /// slower and the window is wider. Staging inverts that: the only step that
  /// touches the real file is a rename, and a failed rename leaves the config
  /// exactly as the user's editor left it.
  Future<void> _writeAtomically(
    File file,
    String contents, {
    Future<void> Function(File staged)? harden,
  }) async {
    final staged = File('${file.path}.karmashala-tmp');
    // A previous run's litter, if the `finally` below never got to run because
    // the process ended between the write and the rename — which a quit that
    // cuts a sweep off at its 150 ms cap can do. Removed rather than written
    // over, so `harden` still applies its ACL to a file this run created.
    await _removeStaged(staged);
    if (harden != null) {
      // The permission goes on the **empty** file, before the token is in it —
      // the same order `LauncherControlServer` uses for its handshake file, and
      // for the same reason: a credential is never written under an ACL that
      // was not applied, not even for the instant before a follow-up call.
      await staged.create(recursive: false);
      await harden(staged);
    }
    await staged.writeAsString(contents, flush: true);
    try {
      await replace(staged, file);
    } finally {
      // Never left behind, whichever way the move went: a stray file in
      // somebody's `.claude` directory is litter we would have to explain.
      await _removeStaged(staged);
    }
  }

  /// Removes a staging file. Never throws: it is somebody else's directory, and
  /// both callers have something better to fail on.
  ///
  /// One call rather than exists-then-delete, which is one file operation
  /// instead of two on a path that may be a `\\wsl.localhost` share — and not
  /// a TOCTOU, which the same shape was here before.
  Future<void> _removeStaged(File staged) async {
    try {
      await staged.delete();
    } on FileSystemException {
      // Not there, or held by something; the next sweep tries again.
    }
  }

  /// The file [descriptor]'s hooks are configured in, or `null` when it has no
  /// hook spec.
  ///
  /// [AgentHookSpec.configFileName] is a path *relative to the store home*, so
  /// it can walk out of it: Antigravity keeps its data in
  /// `~/.gemini/antigravity-cli` and reads `~/.gemini/config/hooks.json`, its
  /// sibling. Normalized rather than joined blindly, so the `..` is resolved
  /// here instead of being handed to the filesystem — a `\\wsl.localhost` UNC
  /// store home is one of the paths this has to survive.
  File? configFileFor(AgentDescriptor descriptor, String storeHome) {
    final spec = descriptor.hooks;
    if (spec == null) return null;
    return File(p.normalize(p.join(storeHome, spec.configFileName)));
  }

  /// One installed handler, in the shape this agent reads.
  Map<String, Object?> _entry(AgentHookEntryStyle style, String command) =>
      switch (style) {
        AgentHookEntryStyle.grouped => {
          'hooks': [
            {'type': 'command', 'command': command},
          ],
        },
        AgentHookEntryStyle.flat => {'type': 'command', 'command': command},
      };

  /// [entries] with our own entries removed. Everything else is carried over
  /// untouched — the list belongs to the user, and only the entries carrying
  /// [agentHookMarker] are ours to drop.
  List<Object?> _withoutOurs(List<Object?> entries) => [
    for (final entry in entries)
      if (!_isOurs(entry)) entry,
  ];

  /// Whether [entries] already holds exactly one entry of ours and it spells
  /// [command] — the case where installing again would rewrite the file to
  /// produce the bytes it already has.
  bool _alreadyCurrent(List<Object?> entries, String command) {
    final ours = entries.where(_isOurs).toList();
    if (ours.length != 1) return false;
    final commands = _commandsIn(ours.single).toList();
    return commands.length == 1 && commands.single == command;
  }

  /// Whether [entry] is one of ours. Exposed for the legacy-marker test, which
  /// has to prove an entry written under an old name is still removable.
  @visibleForTesting
  bool debugIsOurs(Object? entry) => _isOurs(entry);

  /// Ours if it carries the current marker **or** one we used to write.
  bool _isOurs(Object? entry) => _commandsIn(entry).any(
    (command) =>
        command.contains(agentHookMarker) ||
        legacyAgentHookMarkers.any(command.contains),
  );

  /// Every command string an entry carries, whichever shape it is written in.
  ///
  /// Both styles are read regardless of what this agent's spec declares: a
  /// config written by an earlier build, or hand-edited, is still ours to
  /// recognise and take back out on uninstall.
  Iterable<String> _commandsIn(Object? entry) sync* {
    if (entry is! Map) return;
    final grouped = entry['hooks'];
    if (grouped is List) {
      for (final hook in grouped) {
        if (hook is Map && hook['command'] is String) {
          yield hook['command']! as String;
        }
      }
      return;
    }
    if (entry['command'] is String) yield entry['command']! as String;
  }
}

/// Move [staged] onto [destination], replacing it.
///
/// Verified over `\\wsl.localhost\<distro>\home\<user>` as well as on local
/// disk: the moved file lands owned by the distribution's user with mode 644,
/// which is what an agent inside that distribution has to be able to read.
Future<void> _replaceFile(File staged, File destination) =>
    staged.rename(destination.path);

/// Closes [file] to every account on the machine but this one, where this
/// process can assert that from where it is running. Returns whether it was.
///
/// The endpoint file is the only place the hook token is now at rest, so it is
/// worth doing even though the token is the *weak* half of the pair: status
/// reports only, never `/rpc`, and already public to any process running as
/// this user. The boundary being asserted is the other one — **no other
/// unprivileged account** — which is the same boundary
/// `mcp/handshake_file_permissions.dart` establishes for `mcp_bridge.json`, and
/// this is deliberately a narrow re-spelling of it rather than an import:
/// `agents/` does not depend on `mcp/` (see `AgentHookEndpoint`'s class doc for
/// why that rule exists), and a shared helper would have to live somewhere new.
///
/// **Three cases, and only two of them can be asserted from here.**
///
///  * A Windows host writing a `windowsNative` store — `%USERPROFILE%\.claude`
///    and friends. `icacls`, granting the owner, `SYSTEM` and
///    `BUILTIN\Administrators` by well-known SID and then stripping
///    inheritance, so the file stops tracking whatever a GPO or a
///    roaming-profile setup does to its ancestors. That audit is written up in
///    `handshake_file_permissions.dart` and applies here unchanged.
///  * A POSIX host writing a `localPosix` store — `chmod 600`.
///  * A **Windows host writing a WSL store**, across `\\wsl.localhost`. Neither
///    tool applies: `icacls` has no ACL to set on a 9p share, and `chmod` is
///    not a Windows program. The file lands mode 644 in the distribution user's
///    own `$HOME` — the same exposure the generated script has always had
///    there, on a filesystem whose only other account is `root`, which can read
///    it either way. Reported as `false` rather than papered over.
///
/// A `false` is **not** fatal, and that is the opposite of the handshake
/// file's rule. There the ACL was the whole boundary around a credential that
/// opens sessions and drives devices, so a failure withholds the token. Here
/// the credential can do nothing but report a status, the alternative to
/// writing it is an app that cannot see its agents at all, and the file it
/// replaces — the agent's own `settings.json`, carrying this same token inline
/// — never had an asserted ACL in the first place.
Future<bool> restrictToOwner(File file, EnvironmentKind environment) async {
  try {
    if (Platform.isWindows) {
      if (environment != EnvironmentKind.windowsNative) return false;
      final env = Platform.environment;
      final user = env['USERNAME'];
      if (user == null || user.isEmpty) return false;
      final domain = env['USERDOMAIN'];
      final principal = (domain == null || domain.isEmpty)
          ? user
          : '$domain\\$user';
      // Grant first, strip inheritance second: `/inheritance:r` deletes
      // inherited ACEs outright rather than converting them, so the other order
      // leaves a file its own owner cannot open.
      final granted = await Process.run('icacls', [
        file.path,
        '/grant:r',
        '*S-1-5-18:(F)', // NT AUTHORITY\SYSTEM
        '*S-1-5-32-544:(F)', // BUILTIN\Administrators, and it is localised
        '$principal:(F)',
      ]);
      if (granted.exitCode != 0) return false;
      final stripped = await Process.run('icacls', [
        file.path,
        '/inheritance:r',
      ]);
      return stripped.exitCode == 0;
    }
    if (environment != EnvironmentKind.localPosix) return false;
    final result = await Process.run('chmod', ['600', file.path]);
    return result.exitCode == 0;
  } on Object {
    // A machine without `icacls` or `chmod`, a path the tool will not accept.
    // The install goes on: see the class doc for why this is not fatal.
    return false;
  }
}

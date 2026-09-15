import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../util/json_object_splice.dart';
import '../domain/claude_account.dart';
import '../domain/codex_account.dart';

/// A home directory on a machine this host cannot open as a filesystem.
///
/// An SSH host is the case this exists for: its files are reachable over SFTP
/// and by no other means, and `agent_cli` must not depend on the SSH package,
/// so the transport arrives as one of these.
abstract class RemoteHome {
  /// Absolute POSIX path of the home directory on that machine.
  String get homePath;

  /// The file's text, or null when it is not there.
  Future<String?> read(String path);

  /// Writes [contents] at [path], creating parent directories as needed.
  Future<void> write(String path, String contents);

  /// [write], but readable and writable by the owner alone.
  ///
  /// Every credential this file writes goes through here. Claude Code and
  /// Codex both refuse a world-readable credentials file, and on a shared box
  /// so should we.
  Future<void> writePrivate(String path, String contents);
}

/// Copies [account]'s Claude credentials into [home], returning what it wrote.
///
/// Two files, for the reason Claude Code splits them: `.credentials.json`
/// carries the OAuth token and `.claude.json` carries the identity
/// `claude auth status` reports. An account captured before the identity was
/// recorded writes the token alone rather than inventing one.
///
/// Both are spliced into whatever is already there. The credentials file also
/// holds MCP server tokens, and the config file holds the whole of that
/// machine's project state — overwriting either would sign the remote out of
/// things this was never asked to touch.
Future<List<String>> pushClaudeAccount(
  ClaudeAccount account,
  RemoteHome home,
) async {
  final written = <String>[];

  final credentials = p.posix.join(home.homePath, '.claude', '.credentials.json');
  await home.writePrivate(
    credentials,
    _spliced(
      await home.read(credentials),
      'claudeAiOauth',
      account.claudeAiOauth,
    ),
  );
  written.add(credentials);

  final identity = account.oauthAccount;
  if (identity != null) {
    final config = p.posix.join(home.homePath, '.claude.json');
    await home.write(
      config,
      _spliced(await home.read(config), 'oauthAccount', identity),
    );
    written.add(config);
  }
  return written;
}

/// Copies [account]'s Codex credentials into [home], returning what it wrote.
///
/// One file, and Karmashala owns none of its keys, so what was captured is
/// what is written rather than a merge of it into whatever is there.
Future<List<String>> pushCodexAccount(
  CodexAccount account,
  RemoteHome home,
) async {
  final path = p.posix.join(home.homePath, '.codex', 'auth.json');
  await home.writePrivate(path, jsonEncode(account.auth));
  return [path];
}

/// Copies an Antigravity OAuth token into [home], returning what it wrote.
///
/// [token] is the file's text, taken verbatim from the install it was captured
/// from: it is an opaque `{auth_method, id_token, token}` record this app does
/// not parse, and re-encoding it would be a claim about a shape nobody here
/// established.
Future<List<String>> pushAntigravityToken(String token, RemoteHome home) async {
  final path = p.posix.join(
    home.homePath,
    '.gemini',
    'antigravity-cli',
    'antigravity-oauth-token',
  );
  await home.writePrivate(path, token);
  return [path];
}

/// [key] set to [value] inside [existing], or a fresh object when there is no
/// file yet or it is empty. A file that is there but unparseable is replaced:
/// a credentials file we cannot read is one the agent cannot read either.
String _spliced(String? existing, String key, Map<String, dynamic> value) {
  final fresh = jsonEncode({key: value});
  if (existing == null || existing.trim().isEmpty) return fresh;
  try {
    return replaceTopLevelJsonValue(existing, key, jsonEncode(value));
  } on FormatException {
    return fresh;
  }
}

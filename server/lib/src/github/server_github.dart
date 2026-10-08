import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_mcp/access.dart'
    show HandshakePermissions, SystemHandshakePermissions;

import 'owner_only_file.dart';

/// What answers a client's GitHub access requests.
abstract interface class GithubWork {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(GithubAccessRequest<Object?> request);
}

/// Set to `off` and the server never asks gh for a GitHub login.
const String kGithubGhVariable = 'KARMASHALA_GITHUB_GH';

/// The longest token accepted; GitHub's are far shorter.
const int kMaxGithubTokenLength = 1024;

/// This server's GitHub access: the tokens pasted in Settings and each host's
/// choices in `<data>/secrets/github.json`, the credentials that pick a token
/// per host, and the one [client] every GitHub feature calls through. A
/// token leaves this object only in an `Authorization` header to its host.
class ServerGithub implements GithubWork, GithubSavedTokens {
  ServerGithub({
    required String dataDirectory,
    Map<String, String> environment = const {},
    GhLogin? gh,
    DateTime Function()? now,
    HandshakePermissions permissions = const SystemHandshakePermissions(),
    GithubClient Function(GithubCredentials credentials)? clientFor,
  }) : _now = now ?? _utcNow,
       _gh = gh,
       _environment = environment,
       _file = OwnerOnlyJsonFile(
         dataDirectory: dataDirectory,
         fileName: fileName,
         what: 'the GitHub token store',
         permissions: permissions,
       ) {
    _load();
    credentials = GithubCredentials(
      saved: this,
      environment: environment,
      gh: gh,
      choiceOf: choiceOf,
      now: _now,
    );
    client =
        clientFor?.call(credentials) ??
        GithubClient(credentials: credentials, now: _now);
  }

  static const String fileName = 'github.json';

  final DateTime Function() _now;
  final GhLogin? _gh;
  final Map<String, String> _environment;
  final OwnerOnlyJsonFile _file;
  late final GithubCredentials credentials;
  late final GithubClient client;

  final Map<String, _SavedToken> _tokens = {};
  final Map<String, GithubHostChoice> _choices = {};

  static DateTime _utcNow() => DateTime.now().toUtc();

  @override
  String? tokenFor(String host) => _tokens[host]?.token;

  GithubHostChoice choiceOf(String host) =>
      _choices[host] ?? GithubHostChoice.none;

  @override
  Future<Object?> handle(GithubAccessRequest<Object?> request) async =>
      switch (request) {
        GithubAccessRead() => await status(),
        GithubTokenSave(:final host, :final token) => await _save(host, token),
        GithubTokenClear(:final host) => await _clear(host),
        GithubTokenTest(:final host) => await test(host),
        GithubHostChoose(:final host, :final account, :final off) =>
          await _choose(host, account, off: off),
      };

  static String _host(String raw) =>
      normalizeGithubHost(raw) ??
      (throw DataRefused.invalid('Name a GitHub host, such as github.com.'));

  Future<GithubAccessStatus> _save(String rawHost, String rawToken) async {
    final host = _host(rawHost);
    final token = rawToken.trim();
    if (token.isEmpty) throw DataRefused.invalid('Paste a token to save.');
    if (token.length > kMaxGithubTokenLength || token.contains(RegExp(r'\s'))) {
      throw DataRefused.invalid('That does not look like a GitHub token.');
    }
    final before = _tokens[host];
    _tokens[host] = _SavedToken(token: token, savedAt: _now());
    try {
      await _write();
    } on Object {
      _restore(host, before);
      rethrow;
    }
    return status();
  }

  Future<GithubAccessStatus> _clear(String rawHost) async {
    final host = _host(rawHost);
    final before = _tokens.remove(host);
    if (before != null) {
      try {
        await _write();
      } on Object {
        _tokens[host] = before;
        rethrow;
      }
    }
    return status();
  }

  void _restore(String host, _SavedToken? before) {
    if (before == null) {
      _tokens.remove(host);
    } else {
      _tokens[host] = before;
    }
  }

  Future<GithubAccessStatus> _choose(
    String rawHost,
    String? account, {
    required bool off,
  }) async {
    final host = _host(rawHost);
    final before = _choices[host];
    final choice = GithubHostChoice(
      account: account?.trim().isEmpty ?? true ? null : account!.trim(),
      off: off,
    );
    if (choice.account == null && !choice.off) {
      _choices.remove(host);
    } else {
      _choices[host] = choice;
    }
    try {
      await _write();
    } on Object {
      if (before == null) {
        _choices.remove(host);
      } else {
        _choices[host] = before;
      }
      rethrow;
    }
    credentials.forgetGh();
    return status();
  }

  /// `GET /user` as [rawHost]'s saved token, or as the token in use when
  /// none is saved. A saved token's answer is kept for the status line.
  Future<GithubTokenCheck> test(String rawHost) async {
    final host = _host(rawHost);
    final saved = _tokens[host];
    final token = saved != null
        ? GithubToken(
            host: host,
            value: saved.token,
            source: GithubTokenSource.settings,
          )
        : await credentials.tokenFor(host);
    if (token == null) {
      return GithubTokenCheck(
        host: host,
        ok: false,
        message: GithubNoAccess(host, off: choiceOf(host).off).message,
      );
    }
    final GithubResponse response;
    try {
      response = await client.restAs(token, 'user');
    } on GithubApiException catch (error) {
      return GithubTokenCheck(host: host, ok: false, message: error.message);
    }
    final login = (response.body is Map)
        ? (response.body as Map)['login'] as String?
        : null;
    if (!response.ok || login == null) {
      return GithubTokenCheck(
        host: host,
        ok: false,
        message: response.status == 401
            ? 'GitHub did not accept the token (HTTP 401).'
            : 'GitHub answered HTTP ${response.status}'
                  '${response.message == null ? '' : ': ${response.message}'}.',
      );
    }
    if (saved != null && identical(_tokens[host], saved)) {
      _tokens[host] = saved.checked(login, _now());
      try {
        await _write();
      } on Object {
        _tokens[host] = saved;
      }
    }
    return GithubTokenCheck(host: host, ok: true, login: login);
  }

  /// Every host worth showing, and where each one's access comes from.
  Future<GithubAccessStatus> status() async {
    final gh = _gh;
    final reading = gh == null
        ? const GhAccountsReading(
            [],
            problem: 'This server does not ask gh for a login.',
          )
        : await gh.accounts();
    final hosts = <String>{
      kGithubDotCom,
      ..._tokens.keys,
      ..._choices.keys,
      for (final account in reading.accounts) account.host,
      ?normalizeGithubHost(_environment['GH_HOST']),
    }.toList()..sort(_dotComFirst);
    return GithubAccessStatus(
      hosts: [
        for (final host in hosts) await _accessOf(host, reading.accounts),
      ],
      savedTokens: [
        for (final MapEntry(:key, :value) in _tokens.entries)
          GithubSavedToken(
            host: key,
            savedAt: value.savedAt,
            login: value.login,
            checkedAt: value.checkedAt,
          ),
      ],
      ghProblem: reading.problem,
    );
  }

  static int _dotComFirst(String a, String b) {
    if (a == b) return 0;
    if (a == kGithubDotCom) return -1;
    if (b == kGithubDotCom) return 1;
    return a.compareTo(b);
  }

  Future<GithubHostAccess> _accessOf(
    String host,
    List<GhAccount> accounts,
  ) async {
    final reading = await credentials.describe(
      host,
      savedLogin: _tokens[host]?.login,
      ghAccounts: accounts,
    );
    final here = accounts.where((a) => a.host == host).toList();
    final choice = choiceOf(host);
    return GithubHostAccess(
      host: host,
      status: reading.describe,
      source: reading.source?.name,
      login: reading.login,
      off: choice.off,
      account: choice.account,
      ghAccounts: [for (final account in here) account.login],
      ghActiveAccount: here.where((a) => a.active).firstOrNull?.login,
    );
  }

  void _load() {
    final json = _file.read();
    final tokens = json['tokens'];
    if (tokens is Map) {
      for (final MapEntry(:key, :value) in tokens.entries) {
        final host = normalizeGithubHost('$key');
        final saved = _SavedToken.fromJson(value);
        if (host != null && saved != null) _tokens[host] = saved;
      }
    }
    final choices = json['hosts'];
    if (choices is Map) {
      for (final MapEntry(:key, :value) in choices.entries) {
        final host = normalizeGithubHost('$key');
        if (host != null) _choices[host] = GithubHostChoice.fromJson(value);
      }
    }
  }

  Future<void> _write() => _file.write({
    'version': 1,
    'tokens': {
      for (final MapEntry(:key, :value) in _tokens.entries) key: value.toJson(),
    },
    'hosts': {
      for (final MapEntry(:key, :value) in _choices.entries)
        key: value.toJson(),
    },
  });
}

class _SavedToken {
  const _SavedToken({
    required this.token,
    required this.savedAt,
    this.login,
    this.checkedAt,
  });

  final String token;
  final DateTime savedAt;
  final String? login;
  final DateTime? checkedAt;

  _SavedToken checked(String login, DateTime at) =>
      _SavedToken(token: token, savedAt: savedAt, login: login, checkedAt: at);

  Map<String, Object?> toJson() => {
    'token': token,
    'savedAt': savedAt.toIso8601String(),
    'login': ?login,
    'checkedAt': ?checkedAt?.toIso8601String(),
  };

  static _SavedToken? fromJson(Object? json) {
    if (json is! Map || json['token'] is! String) return null;
    return _SavedToken(
      token: json['token'] as String,
      savedAt:
          DateTime.tryParse('${json['savedAt']}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      login: json['login'] as String?,
      checkedAt: DateTime.tryParse('${json['checkedAt']}')?.toUtc(),
    );
  }
}

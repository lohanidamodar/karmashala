part of 'fake_data_server.dart';

/// The server's GitHub access, in memory: a test seeds [status] and reads
/// [savedTokens] (what the server would hold) and [requests] (what was
/// asked). A client hears the status and never a token.
class FakeGithubAccess {
  FakeGithubAccess._(this._server);

  final FakeDataServer _server;

  GithubAccessStatus status = const GithubAccessStatus(
    hosts: [
      GithubHostAccess(
        host: 'github.com',
        status: 'No GitHub access: paste a token or run gh auth login',
      ),
    ],
  );

  /// Host → token, as the server holds them.
  final savedTokens = <String, String>{};

  /// What `GET /user` answers, by token; anything else is a 401.
  final logins = <String, String>{};

  final requests = <DataRequest<Object?>>[];

  Object? _handle(GithubAccessRequest<Object?> request) {
    requests.add(request);
    switch (request) {
      case GithubAccessRead():
        return status;
      case GithubTokenSave(:final host, :final token):
        if (token.trim().isEmpty) {
          throw const DataRefused.invalid('Paste a token to save.');
        }
        savedTokens[host] = token.trim();
        _hostSays(host, 'settings', 'Using your saved token');
        status = GithubAccessStatus(
          hosts: status.hosts,
          savedTokens: [
            for (final saved in status.savedTokens)
              if (saved.host != host) saved,
            GithubSavedToken(host: host, savedAt: _server._now()),
          ],
          ghProblem: status.ghProblem,
        );
        return status;
      case GithubTokenClear(:final host):
        savedTokens.remove(host);
        _hostSays(
          host,
          null,
          'No GitHub access: paste a token or run gh auth login',
        );
        status = GithubAccessStatus(
          hosts: status.hosts,
          savedTokens: [
            for (final saved in status.savedTokens)
              if (saved.host != host) saved,
          ],
          ghProblem: status.ghProblem,
        );
        return status;
      case GithubTokenTest(:final host):
        final login = logins[savedTokens[host]];
        if (login == null) {
          return GithubTokenCheck(
            host: host,
            ok: false,
            message: 'GitHub did not accept the token (HTTP 401).',
          );
        }
        status = GithubAccessStatus(
          hosts: status.hosts,
          savedTokens: [
            for (final saved in status.savedTokens)
              saved.host == host
                  ? GithubSavedToken(
                      host: host,
                      savedAt: saved.savedAt,
                      login: login,
                      checkedAt: _server._now(),
                    )
                  : saved,
          ],
          ghProblem: status.ghProblem,
        );
        return GithubTokenCheck(host: host, ok: true, login: login);
      case GithubHostChoose(:final host, :final account, :final off):
        status = GithubAccessStatus(
          hosts: [
            for (final access in status.hosts)
              access.host == host
                  ? GithubHostAccess(
                      host: host,
                      status: off
                          ? 'GitHub is turned off for $host'
                          : access.status,
                      source: off ? null : access.source,
                      login: access.login,
                      off: off,
                      account: account,
                      ghAccounts: access.ghAccounts,
                      ghActiveAccount: access.ghActiveAccount,
                    )
                  : access,
          ],
          savedTokens: status.savedTokens,
          ghProblem: status.ghProblem,
        );
        return status;
    }
  }

  void _hostSays(String host, String? source, String said) {
    final hosts = [
      for (final access in status.hosts)
        if (access.host != host) access,
    ];
    final before = status.hosts.where((h) => h.host == host).firstOrNull;
    hosts.insert(
      0,
      GithubHostAccess(
        host: host,
        status: said,
        source: source,
        ghAccounts: before?.ghAccounts ?? const [],
        ghActiveAccount: before?.ghActiveAccount,
      ),
    );
    status = GithubAccessStatus(
      hosts: hosts,
      savedTokens: status.savedTokens,
      ghProblem: status.ghProblem,
    );
  }
}

/// Agents' secret requests, in memory: a test calls [ask] as an agent would,
/// and reads [saved] for what the owner gave and [declined].
class FakeSecretRequests {
  FakeSecretRequests._(this._server);

  final FakeDataServer _server;

  final pending = <SecretRequest>[];

  /// Request id → the value the owner saved.
  final saved = <String, String>{};
  final declined = <String>[];

  /// An agent in [sessionId] asks; every link is told.
  SecretRequest ask(String sessionId, {String? label, String? reason}) {
    final request = SecretRequest(
      id: 'secret-${pending.length + saved.length + declined.length + 1}',
      sessionId: sessionId,
      label: label ?? 'Webhook signing secret',
      reason: reason ?? 'To verify the calls the webhook receives.',
      requestedAt: _server._now(),
    );
    pending.add(request);
    _tell();
    return request;
  }

  void _tell() =>
      _server._tell(null, [SecretRequestsChanged(List.of(pending))]);

  Object? _handle(SecretRequestWork<Object?> request) {
    switch (request) {
      case SecretRequestsRead():
        return List.of(pending);
      case SecretProvide(:final id, :final value):
        if (!pending.any((r) => r.id == id)) {
          throw const DataRefused.notFound('no longer waiting');
        }
        if (value.isEmpty) {
          throw const DataRefused.invalid('Enter the secret to save.');
        }
        pending.removeWhere((r) => r.id == id);
        saved[id] = value;
      case SecretDecline(:final id):
        pending.removeWhere((r) => r.id == id);
        declined.add(id);
    }
    _tell();
    return const DataAck();
  }
}

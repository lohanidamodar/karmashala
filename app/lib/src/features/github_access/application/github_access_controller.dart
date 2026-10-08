import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';

/// **The server's GitHub access, as this client may know it**: where each
/// host's token comes from, the saved tokens (when, and who they tested as)
/// and gh's accounts. A token is typed here and sent once in
/// `github.token.save`; no client reads one back. Null until the server has
/// answered.
class GithubAccessController extends Notifier<GithubAccessStatus?> {
  @override
  GithubAccessStatus? build() {
    ref.watch(dataClientProvider);
    unawaited(refresh());
    return null;
  }

  Future<void> refresh() async {
    try {
      state =
          (await ref.read(dataClientProvider).send(const GithubAccessRead()))
              .value;
    } on DataRefused {
      // Nothing learned; the page says nothing is known yet.
    }
  }

  /// Saves [token] for [host] on the server. Throws [DataRefused].
  Future<void> save(String host, String token) async {
    state =
        (await ref.read(dataClientProvider).send(GithubTokenSave(host, token)))
            .value;
  }

  Future<void> clear(String host) async {
    state =
        (await ref.read(dataClientProvider).send(GithubTokenClear(host))).value;
  }

  /// `GET /user` as [host]'s token, then the status it leaves.
  Future<GithubTokenCheck> test(String host) async {
    final check =
        (await ref.read(dataClientProvider).send(GithubTokenTest(host))).value;
    await refresh();
    return check;
  }

  /// gh's [account] for [host] (null follows gh), or the host [off].
  Future<void> choose(String host, {String? account, bool off = false}) async {
    state =
        (await ref
                .read(dataClientProvider)
                .send(GithubHostChoose(host, account: account, off: off)))
            .value;
  }
}

final githubAccessProvider =
    NotifierProvider<GithubAccessController, GithubAccessStatus?>(
      GithubAccessController.new,
    );

import 'package:karmashala_automations/github.dart';
import 'package:karmashala_git/github.dart';

/// GitHub's REST API for a trigger, through the server's [GithubClient] on
/// [host]: the client keeps each path's ETag and waits out a spent budget,
/// which the poller hears as a 403 with nothing left.
class ClientGithubApi implements GithubApi {
  ClientGithubApi(this.client, this.host);

  final GithubClient client;
  final String host;

  @override
  Future<GithubAnswer> get(String path) async {
    final GithubResponse response;
    try {
      response = await client.rest(host, path);
    } on GithubRateLimited catch (spent) {
      return GithubAnswer(
        status: 403,
        body: null,
        remaining: 0,
        resetAt: spent.until,
      );
    } on GithubNoAccess catch (error) {
      throw GithubReadException(error.message);
    } on GithubApiException catch (error) {
      throw GithubReadException(error.message);
    }
    return GithubAnswer(
      status: response.status,
      body: response.body,
      remaining: response.remaining,
      resetAt: response.resetAt,
    );
  }
}

/// The host of a repository's canonical id (`github.com/o/r`), github.com
/// when there is none.
String githubHostOfCanonical(String? canonicalId) {
  final slash = canonicalId?.indexOf('/') ?? -1;
  if (canonicalId == null || slash <= 0) return kGithubDotCom;
  return normalizeGithubHost(canonicalId.substring(0, slash)) ?? kGithubDotCom;
}

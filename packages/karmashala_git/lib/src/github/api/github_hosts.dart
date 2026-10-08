import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The host every GitHub repository without a remote of its own is on.
const String kGithubDotCom = 'github.com';

/// [host] as the credentials and the client key it: lower-case, without a
/// scheme, a path or a trailing dot. Null when nothing is left.
String? normalizeGithubHost(String? host) {
  var value = host?.trim().toLowerCase() ?? '';
  value = value.replaceFirst(RegExp(r'^[a-z][a-z0-9+.\-]*://'), '');
  final slash = value.indexOf('/');
  if (slash >= 0) value = value.substring(0, slash);
  while (value.endsWith('.')) {
    value = value.substring(0, value.length - 1);
  }
  if (value == 'api.github.com' || value == 'www.github.com') {
    return kGithubDotCom;
  }
  return value.isEmpty ? null : value;
}

/// GitHub's data-residency hosts, `<tenant>.ghe.com`, which share
/// github.com's API layout on `api.<host>`.
bool isGheDotCom(String host) => host.endsWith('.ghe.com');

/// Whether [host] is an Enterprise Server rather than a GitHub-run host.
bool isGithubEnterpriseServer(String host) =>
    host != kGithubDotCom && !isGheDotCom(host);

/// The REST root for [host], ending in a slash.
Uri githubApiBase(String host) {
  if (host == kGithubDotCom) return Uri.parse('https://api.github.com/');
  if (isGheDotCom(host)) return Uri.parse('https://api.$host/');
  return Uri.parse('https://$host/api/v3/');
}

/// The GraphQL endpoint for [host]. An Enterprise Server serves it beside,
/// not under, `/api/v3`.
Uri githubGraphqlEndpoint(String host) {
  if (host == kGithubDotCom || isGheDotCom(host)) {
    return githubApiBase(host).resolve('graphql');
  }
  return Uri.parse('https://$host/api/graphql');
}

/// The key a cache or a rate budget is kept under for one token on one host:
/// a hash, so no map, log or dump ever holds the token itself.
String githubTokenKey(String host, String token) =>
    sha256.convert(utf8.encode('$host\n$token')).toString();

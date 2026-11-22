import 'release_version.dart';

/// The public repository releases ship to.
const kReleaseRepository = 'lohanidamodar/karmashala';

/// GitHub's newest published release — drafts and prereleases excluded.
final Uri kLatestReleaseUrl = Uri.parse(
  'https://api.github.com/repos/$kReleaseRepository/releases/latest',
);

/// One file attached to a release.
final class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.size,
    required this.downloadUrl,
    this.digest,
  });

  final String name;

  /// Bytes, as GitHub reports them.
  final int size;

  final Uri downloadUrl;

  /// `sha256:<hex>` when GitHub has one; older uploads have none.
  final String? digest;

  static ReleaseAsset? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['name'];
    final size = json['size'];
    final url = json['browser_download_url'];
    if (name is! String || size is! int || url is! String) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return null;
    final digest = json['digest'];
    return ReleaseAsset(
      name: name,
      size: size,
      downloadUrl: uri,
      digest: digest is String && digest.isNotEmpty ? digest : null,
    );
  }
}

/// A release as `GET /repos/{repo}/releases/latest` answers it, kept to what
/// an update needs.
final class GitHubRelease {
  const GitHubRelease({
    required this.tag,
    required this.version,
    required this.page,
    this.name = '',
    this.notes = '',
    this.assets = const [],
    this.draft = false,
    this.prerelease = false,
  });

  /// `v<version>`.
  final String tag;
  final ReleaseVersion version;

  /// The release's page on GitHub.
  final Uri page;
  final String name;

  /// The release body, as markdown.
  final String notes;
  final List<ReleaseAsset> assets;
  final bool draft;
  final bool prerelease;

  /// The tag without its `v`: what asset names carry.
  String get versionText => tag.startsWith('v') ? tag.substring(1) : tag;

  /// Whether this may be offered at all: published, not a prerelease, and a
  /// tag that reads as a version.
  bool get offerable => !draft && !prerelease && !version.isPrerelease;

  ReleaseAsset? asset(String name) {
    for (final asset in assets) {
      if (asset.name == name) return asset;
    }
    return null;
  }

  /// [json] as a release, or null when it is not one this app can use: no
  /// tag, a tag that is not a version, or no https page.
  static GitHubRelease? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final tag = json['tag_name'];
    final page = json['html_url'];
    if (tag is! String || page is! String) return null;
    final version = ReleaseVersion.tryParse(tag);
    final pageUri = Uri.tryParse(page);
    if (version == null || pageUri == null || pageUri.scheme != 'https') {
      return null;
    }
    final assets = json['assets'];
    return GitHubRelease(
      tag: tag,
      version: version,
      page: pageUri,
      name: json['name'] is String ? json['name'] as String : '',
      notes: json['body'] is String ? json['body'] as String : '',
      draft: json['draft'] == true,
      prerelease: json['prerelease'] == true,
      assets: [
        if (assets is List)
          for (final entry in assets) ?ReleaseAsset.fromJson(entry),
      ],
    );
  }
}

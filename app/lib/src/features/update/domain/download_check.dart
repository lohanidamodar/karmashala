import 'github_release.dart';

/// Whether a downloaded file is the one the release published.
enum DownloadCheck {
  ok,

  /// GitHub's sha256 and the file's differ.
  digestMismatch,

  /// No digest to compare, and the size differs.
  sizeMismatch;

  String get problem => switch (this) {
    ok => '',
    digestMismatch => "the download's checksum did not match the release's",
    sizeMismatch => "the download's size did not match the release's",
  };
}

/// Checks a download of [asset]: GitHub's `sha256:` digest when it has one,
/// the size alone when it does not.
DownloadCheck checkDownload(
  ReleaseAsset asset, {
  required String sha256Hex,
  required int size,
}) {
  final digest = asset.digest;
  const prefix = 'sha256:';
  if (digest != null && digest.toLowerCase().startsWith(prefix)) {
    final expected = digest.substring(prefix.length).trim().toLowerCase();
    return expected == sha256Hex.toLowerCase() && size == asset.size
        ? DownloadCheck.ok
        : DownloadCheck.digestMismatch;
  }
  return size == asset.size ? DownloadCheck.ok : DownloadCheck.sizeMismatch;
}

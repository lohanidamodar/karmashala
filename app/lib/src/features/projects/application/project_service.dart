/// The repository name a clone of [url] gets: its last path segment, without
/// `.git` — what the New Project dialog offers as the project's name. The
/// clone itself, the scan and what is recorded are the server's
/// (`projects.createFromFolder`).
String repoNameFromUrl(String url) {
  var cleaned = url.trim();
  if (cleaned.endsWith('.git')) {
    cleaned = cleaned.substring(0, cleaned.length - 4);
  }
  while (cleaned.endsWith('/')) {
    cleaned = cleaned.substring(0, cleaned.length - 1);
  }
  final slashIndex = cleaned.lastIndexOf('/');
  final colonIndex = cleaned.lastIndexOf(':');
  final lastSep = slashIndex > colonIndex ? slashIndex : colonIndex;
  if (lastSep != -1 && lastSep < cleaned.length - 1) {
    return cleaned.substring(lastSep + 1);
  }
  return cleaned;
}

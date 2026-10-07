import 'dart:typed_data';

/// How a file a conversation names is previewed inline.
enum FilePreviewKind {
  code,
  markdown,
  image,
  svg,
  pdf,
  delimited,
  json,
  yaml,
  html,
  mermaid,
  log,
  other,
}

/// The most of a text file a preview reads.
const int kPreviewTextBytes = 256 * 1024;

/// The largest picture or PDF a preview reads whole.
const int kPreviewMediaBytes = 16 * 1024 * 1024;

String _extension(String path) {
  final name = path.split(RegExp(r'[\\/]')).last.toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(dot + 1);
}

/// The kind [path] previews as, by its name. A file named for text may still
/// turn out binary: [looksBinary] has the last word.
FilePreviewKind previewKindFor(String path) => switch (_extension(path)) {
  'md' || 'markdown' || 'mdx' => FilePreviewKind.markdown,
  'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => FilePreviewKind.image,
  'svg' => FilePreviewKind.svg,
  'pdf' => FilePreviewKind.pdf,
  'csv' || 'tsv' => FilePreviewKind.delimited,
  'json' || 'jsonc' || 'geojson' => FilePreviewKind.json,
  'yaml' || 'yml' => FilePreviewKind.yaml,
  'html' || 'htm' => FilePreviewKind.html,
  'mmd' || 'mermaid' => FilePreviewKind.mermaid,
  'log' || 'ansi' || 'out' => FilePreviewKind.log,
  'zip' ||
  'gz' ||
  'tar' ||
  '7z' ||
  'exe' ||
  'dll' ||
  'so' ||
  'dylib' ||
  'bin' ||
  'class' ||
  'jar' ||
  'apk' ||
  'aab' ||
  'ipa' ||
  'woff' ||
  'woff2' ||
  'ttf' ||
  'otf' ||
  'ico' ||
  'mp4' ||
  'mov' ||
  'mp3' ||
  'wav' ||
  'sqlite' ||
  'db' => FilePreviewKind.other,
  _ => FilePreviewKind.code,
};

/// Whether [kind] is read as text, and so capped at [kPreviewTextBytes].
bool isTextPreview(FilePreviewKind kind) => switch (kind) {
  FilePreviewKind.image ||
  FilePreviewKind.svg ||
  FilePreviewKind.pdf ||
  FilePreviewKind.other => false,
  _ => true,
};

/// The highlighter's language for [path], or null for plain text.
String? previewLanguageFor(String path) {
  final ext = _extension(path);
  return switch (ext) {
    'txt' || 'text' || '' => null,
    'h' || 'hpp' || 'cc' || 'cxx' => 'cpp',
    'mjs' || 'cjs' => 'javascript',
    'kts' => 'kotlin',
    'htm' || 'html' || 'svg' || 'xml' || 'plist' || 'xaml' => 'xml',
    'bat' || 'cmd' => 'dos',
    'toml' || 'ini' || 'cfg' || 'properties' => 'ini',
    'gradle' => 'groovy',
    _ => ext,
  };
}

/// Whether the head of a file is binary: a NUL byte in its first 8 KB, the
/// test `git` and `grep` use.
bool looksBinary(Uint8List head) {
  final n = head.length < 8192 ? head.length : 8192;
  for (var i = 0; i < n; i++) {
    if (head[i] == 0) return true;
  }
  return false;
}

/// [bytes] as a size a person reads: `912 B`, `14.2 KB`, `3.1 MB`.
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

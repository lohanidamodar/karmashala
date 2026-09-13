import 'package:path/path.dart' as p;

/// Host paths are Windows-spelled, so both separators have to split.
final p.Context _hostPaths = p.windows;

/// Every value here is a key `highlight` registers; an id it does not know
/// makes `highlight.parse` throw rather than fall back to plain text.
const Map<String, String> _byExtension = <String, String>{
  'dart': 'dart',
  'js': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'jsx': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'rs': 'rust',
  'go': 'go',
  'java': 'java',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'swift': 'swift',
  // No `c` grammar is registered; C reads acceptably as C++.
  'c': 'cpp',
  'h': 'cpp',
  'cc': 'cpp',
  'cpp': 'cpp',
  'cxx': 'cpp',
  'hpp': 'cpp',
  'cs': 'cs',
  'rb': 'ruby',
  'php': 'php',
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'ps1': 'powershell',
  'sql': 'sql',
  'html': 'xml',
  'htm': 'xml',
  'xml': 'xml',
  'css': 'css',
  'scss': 'scss',
  'less': 'less',
  'json': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'toml': 'ini',
  'md': 'markdown',
  'markdown': 'markdown',
  'ini': 'ini',
  'cfg': 'ini',
  'conf': 'ini',
  'gradle': 'gradle',
  'cmake': 'cmake',
  'lua': 'lua',
  'r': 'r',
  'scala': 'scala',
  'ex': 'elixir',
  'exs': 'elixir',
  'erl': 'erlang',
  'hs': 'haskell',
  'pl': 'perl',
  'vim': 'vim',
  'diff': 'diff',
  'patch': 'diff',
  'proto': 'protobuf',
  'graphql': 'graphql',
  'gql': 'graphql',
};

/// Names git and toolchains use with no extension, plus one whose extension
/// lies: `CMakeLists.txt` is not text.
const Map<String, String> _byName = <String, String>{
  'makefile': 'makefile',
  'dockerfile': 'dockerfile',
  'cmakelists.txt': 'cmake',
  '.env': 'ini',
};

/// The `highlight` language id for [path]'s extension, or null.
String? highlightLanguageFor(String path) {
  final name = _hostPaths.basename(path).toLowerCase();
  final byName = _byName[name];
  if (byName != null) return byName;
  final extension = _hostPaths.extension(path).toLowerCase();
  if (extension.isEmpty) return null;
  return _byExtension[extension.substring(1)];
}

/// Every id [highlightLanguageFor] can answer with. An id `highlight` does not
/// register colours nothing, silently, so a test checks these against it.
Set<String> get highlightLanguageIds => {
  ..._byExtension.values,
  ..._byName.values,
};

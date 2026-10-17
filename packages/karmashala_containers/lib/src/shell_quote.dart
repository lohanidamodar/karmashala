/// [value] as one POSIX shell word: single-quoted, with each `'` closed,
/// escaped and reopened. Nothing inside is expanded by the shell.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// `NAME='value'` for a variable assigned at the top of a script. [name] is
/// Karmashala's own and must be a plain identifier.
String shellAssign(String name, String value) {
  if (!RegExp(r'^[A-Z_][A-Z0-9_]*$').hasMatch(name)) {
    throw ArgumentError.value(name, 'name', 'not a shell variable name');
  }
  return '$name=${shellQuote(value)}';
}

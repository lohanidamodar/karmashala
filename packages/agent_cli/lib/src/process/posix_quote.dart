/// Quotes [value] for a POSIX shell.
///
/// A command line handed to a shell is one string that shell parses, so quoting
/// is the boundary that keeps a repository path containing `;` or `$(...)` from
/// becoming remote code execution. Single quotes suppress every expansion; the
/// only character they cannot contain is a single quote, which is spliced back
/// in as `'\''`.
///
/// This is the `singleQuote` the public `agent_cli` shipped and the `posixQuote`
/// Karmashala's SSH runner has, which are the same function; the SSH runner
/// stays in the app, so the package keeps its own.
String posixQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

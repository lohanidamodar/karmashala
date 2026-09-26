/// Test-side readers for the two parsers a Windows agent launch crosses, so a
/// test can assert on what the *child* receives rather than on our own strings.
library;

/// Splits a Windows command line the way `CommandLineToArgvW` and the MSVC
/// runtime do (the rules `powershell.exe` reads its own line with):
///
/// * space and tab separate arguments outside quotes;
/// * `2n` backslashes then `"` → `n` backslashes, and the quote toggles;
/// * `2n+1` backslashes then `"` → `n` backslashes and a literal `"`;
/// * backslashes not followed by `"` are literal;
/// * `argv[0]` ends at the first unquoted whitespace and knows no escapes.
List<String> commandLineToArgv(String line) {
  final args = <String>[];
  var i = 0;
  // argv[0]: the program name rule.
  while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
    i++;
  }
  if (i >= line.length) return args;
  final program = StringBuffer();
  var quoted = false;
  while (i < line.length) {
    final c = line[i];
    if (c == '"') {
      quoted = !quoted;
    } else if (!quoted && (c == ' ' || c == '\t')) {
      break;
    } else {
      program.write(c);
    }
    i++;
  }
  args.add(program.toString());

  while (true) {
    while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    if (i >= line.length) return args;
    final arg = StringBuffer();
    var inQuotes = false;
    while (i < line.length) {
      final c = line[i];
      if (c == '\\') {
        var n = 0;
        while (i < line.length && line[i] == '\\') {
          n++;
          i++;
        }
        if (i < line.length && line[i] == '"') {
          arg.write('\\' * (n ~/ 2));
          if (n.isOdd) {
            arg.write('"');
            i++;
          }
        } else {
          arg.write('\\' * n);
        }
        continue;
      }
      if (c == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          // The post-2008 runtime's `""` inside quotes.
          arg.write('"');
          i += 2;
          continue;
        }
        inQuotes = !inQuotes;
        i++;
        continue;
      }
      if (!inQuotes && (c == ' ' || c == '\t')) break;
      arg.write(c);
      i++;
    }
    args.add(arg.toString());
  }
}

/// Evaluates the one PowerShell shape `powerShellInvocation` produces —
/// `& <arg> <arg> …`, each argument a single-quoted literal, a
/// `[string]::new([char[]](…))`, or a parenthesised `+` of those — and returns
/// the argv PowerShell hands the command. Anything outside that grammar throws,
/// so a test cannot pass by accident on a script this does not understand.
List<String> evaluatePowerShellInvocation(String script) {
  final p = _PsReader(script);
  p.expect('& ');
  final out = <String>[p.argument()];
  while (!p.done) {
    p.expect(' ');
    out.add(p.argument());
  }
  return out;
}

class _PsReader {
  _PsReader(this.s);
  final String s;
  int i = 0;

  bool get done => i >= s.length;

  void expect(String token) {
    if (!s.startsWith(token, i)) {
      throw FormatException('expected "$token"', s, i);
    }
    i += token.length;
  }

  String argument() {
    if (s.startsWith('(', i)) {
      i++;
      final b = StringBuffer(term());
      while (s.startsWith('+', i)) {
        i++;
        b.write(term());
      }
      expect(')');
      return b.toString();
    }
    return term();
  }

  String term() {
    if (s.startsWith("'", i)) return literal();
    if (s.startsWith('[string]::new([char[]](', i)) {
      i += '[string]::new([char[]]('.length;
      final units = <int>[];
      while (true) {
        final start = i;
        while (i < s.length && '0123456789'.contains(s[i])) {
          i++;
        }
        if (start == i) throw FormatException('expected a number', s, i);
        units.add(int.parse(s.substring(start, i)));
        if (s.startsWith(',', i)) {
          i++;
          continue;
        }
        break;
      }
      expect('))');
      return String.fromCharCodes(units);
    }
    throw FormatException('unexpected term', s, i);
  }

  String literal() {
    expect("'");
    final b = StringBuffer();
    while (true) {
      if (i >= s.length) throw FormatException('unterminated literal', s, i);
      final c = s[i];
      // PowerShell closes a single-quoted string on any of these, not only on
      // the ASCII apostrophe — which is why the producer never emits them raw.
      if ('‘’‚‛'.contains(c)) {
        throw FormatException('a typographic quote inside a literal', s, i);
      }
      if (c == "'") {
        if (s.startsWith("''", i)) {
          b.write("'");
          i += 2;
          continue;
        }
        i++;
        return b.toString();
      }
      b.write(c);
      i++;
    }
  }
}

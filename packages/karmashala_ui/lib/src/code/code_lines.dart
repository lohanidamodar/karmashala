/// True for the code units the engine's paragraph layout starts a new line on.
/// A lone `\r` is deliberately not one — it does not break a paragraph here,
/// and CRLF is handled where a row is cut.
bool isCodeLineBreak(int codeUnit) =>
    codeUnit == 0x0A || // line feed
    codeUnit == 0x0B || // vertical tab
    codeUnit == 0x0C || // form feed
    codeUnit == 0x2028 || // line separator
    codeUnit == 0x2029; // paragraph separator

/// How much of one line is ever measured or drawn. A minified bundle is one
/// line of megabytes, and shaping it whole is the one cost a per-row surface
/// can still hit.
const int kMaxLineUnitsLaidOut = 5000;

/// [line] cut to [kMaxLineUnitsLaidOut] code units, never through a surrogate
/// pair.
String clipLineForLayout(String line) {
  if (line.length <= kMaxLineUnitsLaidOut) return line;
  var end = kMaxLineUnitsLaidOut;
  final last = line.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return line.substring(0, end);
}

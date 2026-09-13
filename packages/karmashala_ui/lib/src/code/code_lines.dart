/// True for the code units the engine's paragraph layout starts a new line on.
/// A lone `\r` is not one of them: it does not break a paragraph here.
bool isCodeLineBreak(int codeUnit) =>
    codeUnit == 0x0A || // line feed
    codeUnit == 0x0B || // vertical tab
    codeUnit == 0x0C || // form feed
    codeUnit == 0x2028 || // line separator
    codeUnit == 0x2029; // paragraph separator

/// How much of one line is ever measured or drawn: a minified bundle is one
/// line of megabytes, and shaping it whole is the one cost a row surface hits.
const int kMaxLineUnitsLaidOut = 5000;

/// [source] from [start] to [end], cut to [kMaxLineUnitsLaidOut] code units and
/// never through a surrogate pair — cut here, so a long line is never copied.
String clipLineForLayout(String source, [int start = 0, int? end]) {
  final stop = end ?? source.length;
  var cut = stop - start > kMaxLineUnitsLaidOut
      ? start + kMaxLineUnitsLaidOut
      : stop;
  if (cut < stop && cut > start) {
    final last = source.codeUnitAt(cut - 1);
    if (last >= 0xD800 && last <= 0xDBFF) cut--;
  }
  return source.substring(start, cut);
}

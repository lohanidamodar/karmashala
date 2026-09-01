// Text → USB HID keystrokes, for typing into a simulator over idb's `hid` RPC.
//
// The `hid` RPC is deliberately primitive: it accepts a stream of presses, and
// a press is a touch point, one of five named buttons, or **a key identified by
// its USB HID usage code** — down, then up. There is no "type this string"
// call. idb's own Python client papers over that in `idb/common/hid.py`, whose
// `KEY_MAP` turns each character into key-down/key-up events and wraps the
// shifted ones in left-shift down/up. This is that map, ported.
//
// Every code below was checked twice, because a wrong one is not a crash but a
// wrong character silently typed into the app under test — the worst outcome
// available to a tool whose whole job is to report what it did:
//
//  1. against idb v1.5.2's `idb/common/hid.py` `KEY_MAP` (the values the
//     companion on the other end of the socket is known to accept), and
//  2. against the USB HID Usage Tables, Keyboard/Keypad page (0x07), via
//     Chromium's `ui/events/keycodes/dom/dom_code_data.inc`, which lists the
//     usage codes as `0x07xxxx` beside the key each one names.
//
// The one gap that looks like a typo and is not: `\` is 49 and `;` is 51.
// Usage 50 (0x070032) is the non-US `#`/`~` key, which a US layout does not
// have, so nothing here claims it.

/// One keystroke: the usage code to press, and whether left shift is held.
///
/// Shift is a property of the keystroke rather than a keystroke of its own
/// because it has to bracket the key press — shift down, key down, key up,
/// shift up. A caller handed a flat list of codes would lose that nesting and
/// type `1` where `!` was asked for.
class HidKeystroke {
  const HidKeystroke(this.usageCode, {this.shift = false});

  /// Usage code on the Keyboard/Keypad page (0x07).
  final int usageCode;

  /// Hold [kHidLeftShift] across this press.
  final bool shift;

  @override
  bool operator ==(Object other) =>
      other is HidKeystroke &&
      other.usageCode == usageCode &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(usageCode, shift);

  @override
  String toString() =>
      shift ? 'HidKeystroke($usageCode, shift)' : 'HidKeystroke($usageCode)';
}

/// Modifier usage codes, for callers that build chords (⌘V and friends).
///
/// Left-hand modifiers throughout: a simulator does not distinguish the two
/// sides, and idb's own `MODIFIER_KEYCODES` sends the left ones.
const int kHidLeftControl = 224;
const int kHidLeftShift = 225;
const int kHidLeftOption = 226;
const int kHidLeftCommand = 227;

/// The US-layout characters that can be typed, and how.
///
/// Keyed by character rather than by code point so the table reads like the
/// keyboard it describes and a wrong entry is visible on inspection.
const Map<String, HidKeystroke> _keyMap = <String, HidKeystroke>{
  // Letters: a..z run unbroken from 4 to 29. Uppercase is the same key with
  // shift held — the usage tables define no separate code for a capital.
  'a': HidKeystroke(4),
  'b': HidKeystroke(5),
  'c': HidKeystroke(6),
  'd': HidKeystroke(7),
  'e': HidKeystroke(8),
  'f': HidKeystroke(9),
  'g': HidKeystroke(10),
  'h': HidKeystroke(11),
  'i': HidKeystroke(12),
  'j': HidKeystroke(13),
  'k': HidKeystroke(14),
  'l': HidKeystroke(15),
  'm': HidKeystroke(16),
  'n': HidKeystroke(17),
  'o': HidKeystroke(18),
  'p': HidKeystroke(19),
  'q': HidKeystroke(20),
  'r': HidKeystroke(21),
  's': HidKeystroke(22),
  't': HidKeystroke(23),
  'u': HidKeystroke(24),
  'v': HidKeystroke(25),
  'w': HidKeystroke(26),
  'x': HidKeystroke(27),
  'y': HidKeystroke(28),
  'z': HidKeystroke(29),
  'A': HidKeystroke(4, shift: true),
  'B': HidKeystroke(5, shift: true),
  'C': HidKeystroke(6, shift: true),
  'D': HidKeystroke(7, shift: true),
  'E': HidKeystroke(8, shift: true),
  'F': HidKeystroke(9, shift: true),
  'G': HidKeystroke(10, shift: true),
  'H': HidKeystroke(11, shift: true),
  'I': HidKeystroke(12, shift: true),
  'J': HidKeystroke(13, shift: true),
  'K': HidKeystroke(14, shift: true),
  'L': HidKeystroke(15, shift: true),
  'M': HidKeystroke(16, shift: true),
  'N': HidKeystroke(17, shift: true),
  'O': HidKeystroke(18, shift: true),
  'P': HidKeystroke(19, shift: true),
  'Q': HidKeystroke(20, shift: true),
  'R': HidKeystroke(21, shift: true),
  'S': HidKeystroke(22, shift: true),
  'T': HidKeystroke(23, shift: true),
  'U': HidKeystroke(24, shift: true),
  'V': HidKeystroke(25, shift: true),
  'W': HidKeystroke(26, shift: true),
  'X': HidKeystroke(27, shift: true),
  'Y': HidKeystroke(28, shift: true),
  'Z': HidKeystroke(29, shift: true),

  // Digits are laid out as the keyboard lays them out — `1` first at 30 — so
  // `0` comes last at 39, not first. Computing a code from the digit's value
  // types `9` when asked for `0`; hence the explicit table.
  '1': HidKeystroke(30),
  '2': HidKeystroke(31),
  '3': HidKeystroke(32),
  '4': HidKeystroke(33),
  '5': HidKeystroke(34),
  '6': HidKeystroke(35),
  '7': HidKeystroke(36),
  '8': HidKeystroke(37),
  '9': HidKeystroke(38),
  '0': HidKeystroke(39),

  // Keys that produce no glyph, reached through the control characters that
  // stand for them. Escape earns its place because a keyboard raised by
  // mistake is dismissed with it and `idb ui button` names no such button.
  '\n': HidKeystroke(40), // Return
  '\u001b': HidKeystroke(41), // Escape
  '\b': HidKeystroke(42), // Backspace
  '\t': HidKeystroke(43), // Tab
  ' ': HidKeystroke(44),

  // Punctuation: the unshifted face of each key, then the shifted face, both
  // in usage-code order so the two halves can be read against each other.
  '-': HidKeystroke(45),
  '=': HidKeystroke(46),
  '[': HidKeystroke(47),
  ']': HidKeystroke(48),
  '\\': HidKeystroke(49),
  ';': HidKeystroke(51),
  "'": HidKeystroke(52),
  '`': HidKeystroke(53),
  ',': HidKeystroke(54),
  '.': HidKeystroke(55),
  '/': HidKeystroke(56),
  '!': HidKeystroke(30, shift: true),
  '@': HidKeystroke(31, shift: true),
  '#': HidKeystroke(32, shift: true),
  '\$': HidKeystroke(33, shift: true),
  '%': HidKeystroke(34, shift: true),
  '^': HidKeystroke(35, shift: true),
  '&': HidKeystroke(36, shift: true),
  '*': HidKeystroke(37, shift: true),
  '(': HidKeystroke(38, shift: true),
  ')': HidKeystroke(39, shift: true),
  '_': HidKeystroke(45, shift: true),
  '+': HidKeystroke(46, shift: true),
  '{': HidKeystroke(47, shift: true),
  '}': HidKeystroke(48, shift: true),
  '|': HidKeystroke(49, shift: true),
  ':': HidKeystroke(51, shift: true),
  '"': HidKeystroke(52, shift: true),
  '~': HidKeystroke(53, shift: true),
  '<': HidKeystroke(54, shift: true),
  '>': HidKeystroke(55, shift: true),
  '?': HidKeystroke(56, shift: true),
};

/// The keystroke that types [character], or null when no key produces it.
///
/// [character] is expected to be a single character; anything longer simply
/// misses the table and reads as untypable.
HidKeystroke? hidKeystrokeFor(String character) => _keyMap[character];

/// The keystrokes that type [text], or **null when any character has no key**.
///
/// All-or-nothing, on purpose. The alternative — skipping what cannot be typed
/// — means asking for `café` and getting `cafe` into the field while the call
/// reports success, after which the caller reasons about a screen that does not
/// exist. Refusing hands that decision back: transliterate, go through the
/// pasteboard, or tell the user this text cannot be typed. Accented letters,
/// CJK and emoji all land here, none being producible on a US HID keyboard.
///
/// `\n` and `\t` **are** typed (Return, 40, and Tab, 43): they are real keys,
/// and submitting a search field by typing its newline is the ordinary reason
/// to send one. `\r` is deliberately absent — it is nearly always half of a
/// CRLF, and honouring it would submit the form a second time, so a caller
/// holding Windows line endings is told to normalise them rather than quietly
/// getting two Returns.
///
/// Iterates by rune, so an emoji is one failed lookup rather than two stray
/// surrogate halves.
List<HidKeystroke>? hidKeystrokesFor(String text) {
  final strokes = <HidKeystroke>[];
  for (final rune in text.runes) {
    final stroke = _keyMap[String.fromCharCode(rune)];
    if (stroke == null) return null;
    strokes.add(stroke);
  }
  return strokes;
}

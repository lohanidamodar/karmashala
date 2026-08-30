import 'dart:convert';

import 'selector_js.dart';

/// The elements a person can act on. Used both to rank text matches (a button
/// beats the `<div>` wrapping it) and to report whether a match is actionable.
const String kInteractiveSelectorJs =
    'a[href],button,input,select,textarea,summary,label,'
    '[role=button],[role=link],[role=tab],[role=menuitem],[role=option],'
    '[role=checkbox],[role=switch],[role=radio],[role=textbox],'
    '[contenteditable=""],[contenteditable=true],[tabindex],[onclick]';

/// Helpers every input script shares: derive a selector, read an element's
/// visible label, decide whether it is visible, and describe it in the JSON
/// shape [FoundElement] parses.
///
/// Kept as one preamble so "what the page says about an element" has a single
/// definition — a find and the click that follows it must agree, or the caller
/// acts on something other than what it was shown.
String _preamble() =>
    '''
$kUniqueSelectorJs
  function label(el) {
    var t = '';
    if (el.getAttribute) {
      t = el.getAttribute('aria-label') || el.getAttribute('placeholder') ||
          el.getAttribute('title') || '';
    }
    var tag = el.tagName;
    if (!t && (tag === 'INPUT' || tag === 'TEXTAREA')) t = el.value || '';
    if (!t && tag === 'IMG') t = el.getAttribute('alt') || '';
    if (!t) t = el.innerText || el.textContent || '';
    return String(t).replace(/\\s+/g, ' ').trim();
  }
  function visible(el, r) {
    if (!r) r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    var s = window.getComputedStyle(el);
    if (!s) return true;
    return s.visibility !== 'hidden' && s.display !== 'none' &&
      parseFloat(s.opacity || '1') > 0.01;
  }
  function interactive(el) {
    try { return !!el.matches && el.matches(${jsonEncode(kInteractiveSelectorJs)}); }
    catch (err) { return false; }
  }
  function describe(el) {
    if (!el || el.nodeType !== 1) return null;
    var r = el.getBoundingClientRect();
    var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    return {
      selector: unique(el),
      tagName: el.tagName.toLowerCase(),
      id: el.id || null,
      classNames: el.classList ? Array.prototype.slice.call(el.classList) : [],
      text: label(el),
      role: el.getAttribute ? el.getAttribute('role') : null,
      visible: visible(el, r),
      interactive: interactive(el),
      inViewport: cx >= 0 && cy >= 0 && cx <= window.innerWidth &&
        cy <= window.innerHeight,
      disabled: !!el.disabled ||
        (el.getAttribute && el.getAttribute('aria-disabled') === 'true'),
      centerX: cx,
      centerY: cy,
      box: {
        x: r.left + window.scrollX,
        y: r.top + window.scrollY,
        width: r.width,
        height: r.height
      }
    };
  }
''';

/// Finds elements by CSS [selector] or by visible [text].
///
/// Text matching is the one that survives a redesign, so it gets the care:
/// it looks at the label a person actually sees (own text, `aria-label`,
/// `placeholder`, `title`, an input's value), keeps only the **innermost**
/// match so an ancestor is never returned for its child's text, and ranks
/// exact over prefix over substring, then interactive over inert, then
/// shortest label. Ordering is what makes "click the element with this text"
/// deterministic instead of a coin toss between a button and its wrapper.
String buildFindElementsScript({
  String? selector,
  String? text,
  bool exact = false,
  bool visibleOnly = true,
  int limit = 25,
}) =>
    '''
(function () {
${_preamble()}
  var SEL = ${jsonEncode(selector)};
  var NEEDLE = ${jsonEncode(text)};
  var EXACT = $exact;
  var VISIBLE_ONLY = $visibleOnly;
  var LIMIT = $limit;

  var matched = [];
  if (SEL !== null) {
    try {
      matched = Array.prototype.slice.call(document.querySelectorAll(SEL));
    } catch (err) {
      return { error: 'invalid selector: ' + err.message };
    }
  } else {
    var needle = EXACT ? NEEDLE : NEEDLE.toLowerCase();
    var all = document.body ? document.body.querySelectorAll('*') : [];
    var hits = [];
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var tag = el.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') continue;
      var value = label(el);
      if (!value) continue;
      var hay = EXACT ? value : value.toLowerCase();
      var rank = -1;
      if (hay === needle) rank = 0;
      else if (!EXACT && hay.indexOf(needle) === 0) rank = 1;
      else if (!EXACT && hay.indexOf(needle) >= 0) rank = 2;
      if (rank < 0) continue;
      hits.push({ el: el, rank: rank });
    }
    var kept = [];
    for (var j = 0; j < hits.length; j++) {
      var wrapsAnother = false;
      for (var k = 0; k < hits.length; k++) {
        if (k !== j && hits[j].el.contains(hits[k].el)) {
          wrapsAnother = true;
          break;
        }
      }
      if (!wrapsAnother) kept.push(hits[j]);
    }
    kept.sort(function (a, b) {
      if (a.rank !== b.rank) return a.rank - b.rank;
      var ai = interactive(a.el) ? 0 : 1, bi = interactive(b.el) ? 0 : 1;
      if (ai !== bi) return ai - bi;
      return label(a.el).length - label(b.el).length;
    });
    for (var m = 0; m < kept.length; m++) matched.push(kept[m].el);
  }

  var out = [];
  var hidden = 0;
  for (var n = 0; n < matched.length && out.length < LIMIT; n++) {
    var described = describe(matched[n]);
    if (!described) continue;
    if (VISIBLE_ONLY && !described.visible) { hidden++; continue; }
    out.push(described);
  }
  return { total: matched.length, hidden: hidden, elements: out };
})()
''';

/// Prepares a click on [selector]: scrolls the element into view, then reports
/// the point to click **and what is actually at that point**.
///
/// Three things are deliberately done here, in the page, rather than in Dart:
///
/// 1. `behavior: 'instant'` — a smooth scroll animates, and a rect read while
///    it is still running names a position the element has already left. Loop
///    35 lost a click to exactly that.
/// 2. The rect is read *after* the scroll, in the same turn, so nothing can
///    move in between.
/// 3. `elementFromPoint` — if a cookie banner covers the button, the click
///    would land on the banner and we would report success. This reports the
///    blocker instead.
String buildClickTargetScript(String selector) =>
    '''
(function () {
${_preamble()}
  var el = document.querySelector(${jsonEncode(selector)});
  if (!el) return { ok: false, reason: 'gone' };
  if (el.scrollIntoView) {
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
  }
  var described = describe(el);
  var r = el.getBoundingClientRect();
  if (r.width <= 0 || r.height <= 0) {
    return { ok: false, reason: 'empty', element: described };
  }
  var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
  if (cx < 0 || cy < 0 || cx > window.innerWidth || cy > window.innerHeight) {
    return { ok: false, reason: 'offscreen', element: described, x: cx, y: cy };
  }
  var hit = document.elementFromPoint(cx, cy);
  var reaches = hit && (hit === el || el.contains(hit) || hit.contains(el));
  if (!reaches) {
    return {
      ok: false,
      reason: 'covered',
      element: described,
      blocker: describe(hit),
      x: cx,
      y: cy
    };
  }
  return { ok: true, element: describe(el), x: cx, y: cy };
})()
''';

/// Focuses the field matching [selector] and selects what it already holds, so
/// the text that follows replaces it rather than appending to it.
///
/// `<select>` is handled here outright — there is no keystroke that picks an
/// option — by matching [value] against option values *and* their visible
/// labels, then firing `input` and `change` so a framework notices.
String buildPrepareFieldScript(String selector, String value) =>
    '''
(function () {
${_preamble()}
  var el = document.querySelector(${jsonEncode(selector)});
  if (!el) return { ok: false, reason: 'gone' };
  if (el.scrollIntoView) {
    el.scrollIntoView({ block: 'center', behavior: 'instant' });
  }
  var described = describe(el);
  var tag = el.tagName.toLowerCase();
  var VALUE = ${jsonEncode(value)};

  if (tag === 'select') {
    var chosen = -1;
    for (var i = 0; i < el.options.length; i++) {
      var option = el.options[i];
      if (option.value === VALUE || String(option.text).trim() === VALUE) {
        chosen = i;
        break;
      }
    }
    if (chosen < 0) {
      var names = [];
      for (var j = 0; j < el.options.length && j < 20; j++) {
        names.push(String(el.options[j].text).trim());
      }
      return { ok: false, reason: 'nooption', element: described, options: names };
    }
    el.focus();
    el.selectedIndex = chosen;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return { ok: true, mode: 'select', element: described, value: el.value };
  }

  var uneditableInput = ['checkbox', 'radio', 'file', 'button', 'submit',
    'reset', 'image', 'range', 'color'];
  if (tag === 'input' && uneditableInput.indexOf((el.type || '').toLowerCase()) >= 0) {
    return { ok: false, reason: 'notext', element: described, type: el.type };
  }
  if (tag !== 'input' && tag !== 'textarea' && !el.isContentEditable) {
    return { ok: false, reason: 'noteditable', element: described };
  }
  if (el.disabled) return { ok: false, reason: 'disabled', element: described };
  if (el.readOnly) return { ok: false, reason: 'readonly', element: described };

  el.focus();
  var had = el.value !== undefined ? el.value : (el.innerText || '');
  if (el.select) {
    try { el.select(); } catch (err) { /* not a text control after all */ }
  } else if (el.isContentEditable) {
    var range = document.createRange();
    range.selectNodeContents(el);
    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }
  return {
    ok: true,
    mode: 'text',
    element: described,
    had: had,
    focused: document.activeElement === el
  };
})()
''';

/// Reads back what a field holds — the only honest way to say a fill worked.
String buildReadFieldScript(String selector) =>
    '(function(){var el=document.querySelector(${jsonEncode(selector)});'
    'if(!el)return null;'
    'if(el.value!==undefined)return String(el.value);'
    'if(el.isContentEditable)return String(el.innerText||"");'
    'return null;})()';

/// Describes whatever currently has focus, so typing with no target can still
/// say where the text went.
String buildActiveElementScript() =>
    '''
(function () {
${_preamble()}
  var el = document.activeElement;
  if (!el || el === document.body) return null;
  return describe(el);
})()
''';

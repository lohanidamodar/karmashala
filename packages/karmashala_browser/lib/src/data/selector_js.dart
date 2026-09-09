/// JavaScript that derives a CSS selector for an element and **verifies it**.
///
/// Shared by the element picker and the input verbs so there is exactly one
/// definition of "a selector for this element": an id when the id is unique,
/// otherwise a structural `tag:nth-of-type(n) > …` path — and, either way,
/// `null` unless `document.querySelector` resolves it back to the same node.
/// A selector that points somewhere else is worse than none at all, because
/// the caller would act on the wrong element and be told it worked.
const String kUniqueSelectorJs = r'''
  function unique(el) {
    if (!el || el.nodeType !== 1) return null;
    var esc = (window.CSS && CSS.escape)
      ? function (s) { return CSS.escape(s); }
      : function (s) { return s; };
    var parts = [];
    var node = el;
    while (node && node.nodeType === 1) {
      if (node.id) {
        var byId = '#' + esc(node.id);
        try {
          if (document.querySelectorAll(byId).length === 1) {
            parts.unshift(byId);
            node = null;
            break;
          }
        } catch (err) { /* invalid id, fall through to the structural path */ }
      }
      var part = node.tagName.toLowerCase();
      var parent = node.parentElement;
      if (parent) {
        var same = 0, index = 0;
        for (var i = 0; i < parent.children.length; i++) {
          var child = parent.children[i];
          if (child.tagName === node.tagName) {
            same++;
            if (child === node) index = same;
          }
        }
        if (same > 1) part += ':nth-of-type(' + index + ')';
      }
      parts.unshift(part);
      node = parent;
    }
    var selector = parts.join(' > ');
    if (!selector) return null;
    try {
      return document.querySelector(selector) === el ? selector : null;
    } catch (err) { return null; }
  }
''';

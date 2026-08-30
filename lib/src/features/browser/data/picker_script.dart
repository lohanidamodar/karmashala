import 'dart:convert';

import 'selector_js.dart';

/// Name of the CDP binding the injected picker calls to report a selection.
///
/// `Runtime.addBinding` installs a function of this name on the page's global
/// object; calling it emits a `Runtime.bindingCalled` event on our socket.
/// That is how a click inside the page becomes a message on the wire.
const String kPickerBindingName = '__chitraguptaPick';

/// Global the injected picker parks its own teardown function on, so a second
/// pick (or an explicit cancel) can dismantle the first cleanly.
const String kPickerNamespace = '__chitraguptaPicker';

/// The script injected into the page while picking.
///
/// Deliberately small and self-removing: it adds one absolutely-positioned
/// overlay and six capture-phase listeners, and `stop()` removes every one of
/// them plus the global it parked. It runs `stop()` **before** reporting, so
/// the highlight is never baked into the screenshot that follows.
String buildPickerScript({
  String bindingName = kPickerBindingName,
  String namespace = kPickerNamespace,
}) => _pickerSource
    .replaceAll('__UNIQUE__', kUniqueSelectorJs.trimRight())
    .replaceAll('__BINDING__', bindingName)
    .replaceAll('__NAMESPACE__', namespace);

/// Script that describes the element matching [selector], in the same JSON
/// shape the picker reports, or `null` when nothing matches.
String buildDescribeSelectorScript(String selector) {
  final literal = jsonEncode(selector);
  return '(function(){var el=document.querySelector($literal);'
      'if(!el)return null;var r=el.getBoundingClientRect();'
      'return {ok:true,selector:$literal,'
      'tagName:el.tagName.toLowerCase(),id:el.id||null,'
      'classNames:el.classList?Array.prototype.slice.call(el.classList):[],'
      'box:{x:r.left+window.scrollX,y:r.top+window.scrollY,'
      'width:r.width,height:r.height},'
      'url:location.href,title:document.title};})()';
}

/// Script that tears down a running picker, returning whether one was there.
String buildPickerStopScript({String namespace = kPickerNamespace}) =>
    "(function(){var p=window['$namespace'];"
    'if(p&&p.stop){p.stop();return true;}return false;})()';

const String _pickerSource = r'''
(function () {
  var NS = '__NAMESPACE__';
  if (window[NS] && window[NS].stop) { window[NS].stop(); }

  var overlay = document.createElement('div');
  overlay.setAttribute('data-chitragupta-picker', '');
  overlay.style.cssText =
    'position:fixed;z-index:2147483647;pointer-events:none;box-sizing:border-box;' +
    'border:2px solid #4f9dff;background:rgba(79,157,255,0.16);' +
    'border-radius:2px;margin:0;padding:0;display:none;transition:none;';
  (document.body || document.documentElement).appendChild(overlay);

  var current = null;

  function target(e) {
    var path = e.composedPath ? e.composedPath() : null;
    var el = path && path.length ? path[0] : e.target;
    while (el && el.nodeType !== 1) { el = el.parentNode; }
    return el;
  }

__UNIQUE__

  function describe(el, x, y) {
    var r = el.getBoundingClientRect();
    return {
      ok: true,
      selector: unique(el),
      tagName: el.tagName.toLowerCase(),
      id: el.id || null,
      classNames: el.classList ? Array.prototype.slice.call(el.classList) : [],
      clientX: x,
      clientY: y,
      box: {
        x: r.left + window.scrollX,
        y: r.top + window.scrollY,
        width: r.width,
        height: r.height
      },
      url: location.href,
      title: document.title
    };
  }

  function report(payload) {
    try { window['__BINDING__'](JSON.stringify(payload)); } catch (err) { }
  }

  function onMove(e) {
    var el = target(e);
    if (!el || el === overlay) return;
    current = el;
    var r = el.getBoundingClientRect();
    overlay.style.display = 'block';
    overlay.style.left = r.left + 'px';
    overlay.style.top = r.top + 'px';
    overlay.style.width = r.width + 'px';
    overlay.style.height = r.height + 'px';
  }

  function swallow(e) {
    e.preventDefault();
    e.stopPropagation();
    if (e.stopImmediatePropagation) e.stopImmediatePropagation();
  }

  function onDown(e) {
    var el = target(e);
    if (el && el !== overlay) current = el;
    swallow(e);
  }

  function onClick(e) {
    swallow(e);
    var el = current || target(e);
    if (!el) return;
    var payload = describe(el, e.clientX, e.clientY);
    stop();
    report(payload);
  }

  function onKey(e) {
    if (e.key !== 'Escape' && e.keyCode !== 27) return;
    swallow(e);
    stop();
    report({ ok: false, cancelled: true });
  }

  function stop() {
    document.removeEventListener('mousemove', onMove, true);
    document.removeEventListener('mousedown', onDown, true);
    document.removeEventListener('mouseup', swallow, true);
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('contextmenu', swallow, true);
    window.removeEventListener('keydown', onKey, true);
    if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
    try { delete window[NS]; } catch (err) { window[NS] = undefined; }
  }

  document.addEventListener('mousemove', onMove, true);
  document.addEventListener('mousedown', onDown, true);
  document.addEventListener('mouseup', swallow, true);
  document.addEventListener('click', onClick, true);
  document.addEventListener('contextmenu', swallow, true);
  window.addEventListener('keydown', onKey, true);
  window[NS] = { stop: stop };
  return true;
})()
''';

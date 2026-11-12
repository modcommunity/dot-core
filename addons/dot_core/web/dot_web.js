/* dot-core's page side of DotWeb. Load before index.js (export-web copies it beside the build).
 * Why a file: the game origin's CSP has no 'unsafe-eval', so JavaScriptBridge.eval throws EvalError.
 * First-party script is allowed, so every browser call DotWeb makes is a named function here,
 * reached through get_interface("dotWeb"). Do not add a path that evaluates a string. */
(function () {
  'use strict';
  if (window.dotWeb) { return; }

  var w = { version: 1, fsSyncFailures: 0, storageEstimate: '', published: {}, publishedAt: {} };
  window.dotWeb = w;

  /* The engine only prints a failed IndexedDB save; counting the print is the one way to see it. */
  var origError = console.error;
  console.error = function () {
    if (arguments.length && String(arguments[0]).indexOf('Failed to save IDB file system') >= 0) {
      w.fsSyncFailures++;
    }
    return origError.apply(console, arguments);
  };

  /* Ctrl+W/T/N cannot be cancelled by a page; the leave prompt covers them while armed. */
  var guard = window.__dotTabGuard = window.__dotTabGuard || { armed: false };
  window.addEventListener('beforeunload', function (e) {
    if (!guard.armed) { return; }
    e.preventDefault();
    e.returnValue = '';
    return '';
  });

  w.lockKeyboard = function () {
    var k = navigator.keyboard;
    if (!k || !k.lock) { return false; }
    try { var p = k.lock(); if (p && p.catch) { p.catch(function () {}); } } catch (err) { return false; }
    return true;
  };
  w.unlockKeyboard = function () {
    var k = navigator.keyboard;
    try { if (k && k.unlock) { k.unlock(); } } catch (err) { /* nothing to release */ }
  };
  /* Escape must not leave fullscreen, so lock whenever the page enters it, however it got there. */
  document.addEventListener('fullscreenchange', function () {
    if (document.fullscreenElement) { w.lockKeyboard(); } else { w.unlockKeyboard(); }
  });

  /* JSON text in, because only primitives cross the bridge cheaply. */
  w.postToParent = function (json) {
    try {
      if (!window.parent || window.parent === window) { return false; }
      window.parent.postMessage(JSON.parse(json), '*');
      return true;
    } catch (err) { return false; }
  };

  w.isMetered = function () {
    var c = navigator.connection;
    return !!(c && (c.saveData === true || c.type === 'cellular'));
  };

  w.downloadText = function (text, filename) {
    var b = new Blob([text], { type: 'text/plain' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(b);
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
  };

  /* A Promise cannot be awaited from GDScript: start it, then poll the property. '' means pending. */
  w.startStorageEstimate = function () {
    w.storageEstimate = '';
    if (!(navigator.storage && navigator.storage.estimate)) { return false; }
    navigator.storage.estimate().then(function (e) {
      w.storageEstimate = JSON.stringify({ usage: e.usage || 0, quota: e.quota || 0 });
    }).catch(function () {
      w.storageEstimate = '{"usage":0,"quota":0}';
    });
    return true;
  };
  w.requestPersistentStorage = function () {
    if (navigator.storage && navigator.storage.persist) {
      navigator.storage.persist().catch(function () {});
    }
  };

  /* Whole-body GET for DotWeb.fetch_bytes. The engine's HTTPRequest reads one stream chunk per frame
   * (~0.4 MB/s at 60 fps); arrayBuffer() lets the browser read at line speed and hands over one buffer. */
  var fetches = {};
  var fetchNext = 1;
  w.fetchStart = function (url, headersJson, timeoutMs, maxBytes) {
    if (typeof fetch !== 'function' || typeof AbortController !== 'function') { return 0; }
    var id = fetchNext++;
    var f = { done: false, info: '', body: null, ctl: new AbortController(), timer: 0 };
    fetches[id] = f;
    var finish = function (info, body) {
      if (f.done) { return; }
      f.done = true;
      f.info = JSON.stringify(info);
      f.body = body;
      if (f.timer) { clearTimeout(f.timer); }
    };
    if (timeoutMs > 0) {
      f.timer = setTimeout(function () { finish({ error: 'timeout' }, null); f.ctl.abort(); }, timeoutMs);
    }
    var headers = {};
    try { headers = JSON.parse(headersJson) || {}; } catch (e) { headers = {}; }
    fetch(url, { method: 'GET', headers: headers, signal: f.ctl.signal }).then(function (resp) {
      var list = [];
      resp.headers.forEach(function (v, k) { list.push(k + ': ' + v); });
      var len = Number(resp.headers.get('content-length') || 0);
      if (maxBytes > 0 && len > maxBytes) {
        finish({ error: 'too_large', status: resp.status, size: len }, null);
        f.ctl.abort();
        return null;
      }
      return resp.arrayBuffer().then(function (buf) {
        if (maxBytes > 0 && buf.byteLength > maxBytes) {
          finish({ error: 'too_large', status: resp.status, size: buf.byteLength }, null);
          return;
        }
        finish({ status: resp.status, headers: list, size: buf.byteLength }, new Uint8Array(buf));
      });
    }).catch(function (e) {
      finish({ error: 'network', detail: String(e && e.message || e) }, null);
    });
    return id;
  };
  /* '' while in flight, then the JSON {status, headers, size} or {error, detail}. */
  w.fetchPoll = function (id) {
    var f = fetches[id];
    if (!f) { return '{"error":"unknown"}'; }
    return f.done ? f.info : '';
  };
  /* The body as a Uint8Array (null when there is none); forgets the fetch. */
  w.fetchTake = function (id) {
    var f = fetches[id];
    delete fetches[id];
    return f ? f.body : null;
  };
  w.fetchDrop = function (id) {
    var f = fetches[id];
    delete fetches[id];
    if (f && !f.done) { f.done = true; f.ctl.abort(); }
  };

  /* A named string for a harness (Playwright) to read: window.dotWeb.published[key] and its performance.now() in publishedAt[key]. */
  w.publish = function (key, text) { w.published[key] = text; w.publishedAt[key] = performance.now(); };
})();

/*
 * MDReader page controller. Native shells call window.MDReader.* and receive
 * messages through postNative():
 *   {type:"ready"} {type:"edited", text} {type:"mode", edit}
 *   {type:"wikilink", path, heading} {type:"chrome", bg, dark}
 */
(function () {
  "use strict";

  var root = document.documentElement;
  var body = document.body;
  var content = document.getElementById("content");
  var tocList = document.getElementById("toc-list");
  var preview = document.getElementById("preview-pane");
  var editorPane = document.getElementById("editor-pane");
  var shade = document.getElementById("top-shade");
  var toastEl = document.getElementById("toast");

  var baseURL = null;
  var lang = "zh";
  var settings = { style: "github", theme: "auto", zoom: 1, toc: true };
  var editing = false;
  var firstRender = true;

  function postNative(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.native) {
        window.webkit.messageHandlers.native.postMessage(msg);
      } else if (window.chrome && window.chrome.webview) {
        window.chrome.webview.postMessage(msg);
      }
    } catch (e) { /* ignore */ }
  }

  var T = {
    zh: { toc: "目录", files: "文件", find: "查找", empty: "空文档", notFound: "未找到：", noFiles: "此文件夹中没有 Markdown 文件", pin: "固定侧栏", unpin: "取消固定" },
    en: { toc: "Contents", files: "Files", find: "Find", empty: "Empty document", notFound: "Not found: ", noFiles: "No Markdown files here", pin: "Pin sidebar", unpin: "Unpin sidebar" }
  };
  function t(k) { return (T[lang] || T.en)[k]; }

  // ---------- Links & sanitising ----------

  var hasScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;
  function resolve(href) {
    if (!baseURL || !href || href.charAt(0) === "#" || hasScheme.test(href)) return null;
    try { return new URL(href, baseURL).href; } catch (e) { return null; }
  }

  function sanitize(container) {
    container.querySelectorAll("script, iframe, object, embed, base, meta, link, form").forEach(function (el) { el.remove(); });
    container.querySelectorAll("*").forEach(function (el) {
      for (var i = el.attributes.length - 1; i >= 0; i--) {
        var a = el.attributes[i];
        var name = a.name.toLowerCase();
        if (name.indexOf("on") === 0) el.removeAttribute(a.name);
        else if ((name === "href" || name === "src" || name === "xlink:href") &&
                 /^\s*(javascript|vbscript):/i.test(a.value)) el.removeAttribute(a.name);
      }
    });
  }

  function fixLinks(container) {
    container.querySelectorAll("img[src], video[src], audio[src], source[src]").forEach(function (el) {
      var abs = resolve(el.getAttribute("src"));
      if (abs) el.setAttribute("src", abs);
    });
    container.querySelectorAll("img[data-wikilink]").forEach(function (el) {
      var abs = resolve(encodeURI(el.getAttribute("data-wikilink")));
      if (abs) el.setAttribute("src", abs);
    });
    container.querySelectorAll("a[href]:not([data-wikilink])").forEach(function (a) {
      var abs = resolve(a.getAttribute("href"));
      if (abs) a.setAttribute("href", abs);
    });
  }

  // ---------- TOC ----------

  var tocLinks = [];
  function buildTOC(headings) {
    tocList.innerHTML = "";
    if (!headings.length) {
      var empty = document.createElement("div");
      empty.className = "toc-empty";
      empty.textContent = "—";
      tocList.appendChild(empty);
      tocLinks = [];
      return;
    }
    var minDepth = Math.min.apply(null, headings.map(function (h) { return h.depth; }));
    headings.forEach(function (h) {
      var a = document.createElement("a");
      a.href = "#" + h.id;
      a.textContent = h.text;
      a.title = h.text;
      a.className = "d" + (h.depth - minDepth + 1);
      a.dataset.target = h.id;
      tocList.appendChild(a);
    });
    tocLinks = Array.prototype.slice.call(tocList.querySelectorAll("a[data-target]"));
    updateActive();
  }

  var activeLink = null;
  function updateActive() {
    if (!tocLinks.length) return;
    var current = tocLinks[0];
    var top = preview.getBoundingClientRect().top + 80;
    for (var i = 0; i < tocLinks.length; i++) {
      var el = document.getElementById(tocLinks[i].dataset.target);
      if (!el) continue;
      if (el.getBoundingClientRect().top <= top) current = tocLinks[i]; else break;
    }
    if (current === activeLink) return;
    if (activeLink) activeLink.classList.remove("active");
    current.classList.add("active");
    activeLink = current;
    var lr = current.getBoundingClientRect(), cr = tocList.getBoundingClientRect();
    if (lr.top < cr.top + 20 || lr.bottom > cr.bottom - 20) {
      tocList.scrollTo({ top: current.offsetTop - tocList.clientHeight / 2, behavior: "smooth" });
    }
  }

  function scrollToId(id) {
    var el = document.getElementById(id) || document.getElementsByName(id)[0];
    if (el) el.scrollIntoView({ behavior: "smooth", block: "start" });
    return !!el;
  }

  // ---------- Scrolling: shade, scroll-spy, editor sync ----------

  var activePane = preview;
  [preview, editorPane].forEach(function (p) {
    p.addEventListener("pointerenter", function () { activePane = p; });
    p.addEventListener("wheel", function () { activePane = p; }, { passive: true });
  });
  editorPane.addEventListener("focusin", function () { activePane = editorPane; });

  function syncFrom(src, dst) {
    var max = src.scrollHeight - src.clientHeight;
    var ratio = max > 0 ? src.scrollTop / max : 0;
    dst.scrollTop = ratio * (dst.scrollHeight - dst.clientHeight);
  }

  var tick = false;
  function onScroll(e) {
    var p = e.currentTarget;
    if (editing && p === activePane) {
      if (p === editorPane) syncPreviewToEditor(); else syncEditorToPreview();
    }
    if (tick) return;
    tick = true;
    requestAnimationFrame(function () {
      tick = false;
      var s = (editing ? activePane : preview).scrollTop;
      shade.classList.toggle("on", s > 4);
      updateActive();
    });
  }
  preview.addEventListener("scroll", onScroll, { passive: true });
  editorPane.addEventListener("scroll", onScroll, { passive: true });

  // ---------- Clicks ----------

  document.addEventListener("click", function (e) {
    var a = e.target.closest && e.target.closest("a[href]");
    if (!a) return;
    var wl = a.getAttribute("data-wikilink");
    if (wl != null) {
      e.preventDefault();
      var heading = a.getAttribute("data-heading") || "";
      if (!wl) {
        var match = tocLinks.filter(function (l) { return l.textContent.trim() === heading.trim(); })[0];
        if (!match || !scrollToId(match.dataset.target)) toast(t("notFound") + heading);
        return;
      }
      postNative({ type: "wikilink", path: wl, heading: heading });
      return;
    }
    var href = a.getAttribute("href");
    if (href && href.charAt(0) === "#") {
      e.preventDefault();
      scrollToId(decodeURIComponent(href.slice(1)));
    }
  });

  // ---------- Rendering ----------

  function renderMarkdown(md, keepScroll, animate) {
    var max = preview.scrollHeight - preview.clientHeight;
    var ratio = keepScroll && max > 0 ? preview.scrollTop / max : 0;
    var findOpen = findbar.classList.contains("open");
    hits = []; hitIndex = -1;

    var out;
    try {
      out = MDCore.toHTML(md);
    } catch (e) {
      out = { html: "<pre>" + MDCore.escapeHTML(String(e && e.stack || e)) + "</pre>", headings: [] };
    }
    content.innerHTML = String(md || "").trim() ? (out.html || "") : '<div class="empty-doc">' + t("empty") + "</div>";
    sanitize(content);
    fixLinks(content);
    activeLink = null;
    buildTOC(out.headings);

    if (keepScroll) preview.scrollTop = ratio * (preview.scrollHeight - preview.clientHeight);
    else preview.scrollTop = 0;

    if (animate) {
      content.classList.remove("enter");
      void content.offsetWidth;
      content.classList.add("enter");
    }
    body.classList.remove("loading");
    if (findOpen && findInput.value) runFind(findInput.value, true);
    updateActive();
    if (editing) { content.appendChild(syncCaret); scheduleCaretSync(false); }
    return out.headings.length;
  }

  // ---------- Editor ----------

  var postTimer = null, previewTimer = null;
  var editor = new MDEditor(document.getElementById("editor"), document.getElementById("editor-hl"), function (text) {
    clearTimeout(previewTimer);
    previewTimer = setTimeout(function () { renderMarkdown(text, true, false); }, 140);
    clearTimeout(postTimer);
    postTimer = setTimeout(function () { postNative({ type: "edited", text: text }); }, 60);
  });

  function setMode(edit) {
    edit = !!edit;
    if (edit === editing) return editing;
    editing = edit;
    if (edit) {
      syncFrom(preview, editorPane);
      activePane = editorPane;
    }
    body.classList.toggle("editing", edit);
    if (edit) setTimeout(function () { editor.focus(); scheduleCaretSync(true); }, 60);
    else { activePane = preview; flushEdits(); hideCaret(); }
    postNative({ type: "mode", edit: edit });
    return editing;
  }

  function flushEdits() {
    if (postTimer) { clearTimeout(postTimer); postTimer = null; postNative({ type: "edited", text: editor.value() }); }
  }

  // ---------- Editor ⇄ preview position sync ----------

  var ta = document.getElementById("editor");
  var hl = document.getElementById("editor-hl");
  var syncCaret = document.createElement("div");
  syncCaret.className = "sync-caret";

  function collapse(str) { return str.replace(/\s+/g, " ").replace(/^ /, ""); }

  /** Length of the block-level markup at the start of a source line (#, >, -, 1., [ ], |). */
  function markerLength(line, isCode) {
    if (isCode) return 0;
    var m = /^(\s{0,3}#{1,6}\s+|(\s*>\s?)+(\[![A-Za-z]+\][+-]?\s*)?|\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?|\s*\|)?/.exec(line);
    return m ? m[0].length : 0;
  }

  /** What a slice of source text looks like once rendered (roughly). */
  function stripInline(text, isCode) {
    if (isCode) return text;
    return text
      .replace(/!?\[\[([^\]|]*?)(?:\\?\|([^\]]*))?\]\]/g, function (_, a, b) { return b || a.split("/").pop(); })
      .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/<[^>]+>/g, "")
      .replace(/(\*\*|__|~~|==|\*|`)/g, "")
      .replace(/\\([\\`*_{}\[\]()#+\-.!|])/g, "$1")
      .replace(/\s*\|\s*$/, "")
      .replace(/\s*\|\s*/g, " ");
  }

  function stripLine(line, isCode) { return stripInline(line.slice(markerLength(line, isCode)), isCode); }

  function blockForLine(line) {
    var best = null, bestLine = -1;
    content.querySelectorAll("[data-line]").forEach(function (el) {
      var l = +el.getAttribute("data-line");
      if (l <= line && l >= bestLine) { best = el; bestLine = l; }
    });
    return best;
  }

  function textRoot(el) { return el.tagName === "PRE" ? (el.querySelector("code") || el) : el; }

  function textNodes(root) {
    var out = [];
    var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        var p = n.parentNode;
        return p && p.closest && p.closest(".code-lang, .anchor, .sync-caret") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      }
    });
    while (w.nextNode()) out.push(w.currentNode);
    return out;
  }

  /** DOM point after `count` rendered characters inside root (whitespace collapsed unless code). */
  function domPointAt(root, count, isCode) {
    var nodes = textNodes(root), seen = 0, prevSpace = true, last = null;
    for (var i = 0; i < nodes.length; i++) {
      var v = nodes[i].nodeValue;
      for (var j = 0; j < v.length; j++) {
        if (seen >= count) return { node: nodes[i], offset: j };
        var sp = /\s/.test(v[j]);
        if (isCode) seen++;
        else if (sp) { if (!prevSpace) { seen++; prevSpace = true; } }
        else { seen++; prevSpace = false; }
      }
      last = nodes[i];
    }
    return last ? { node: last, offset: last.nodeValue.length } : null;
  }

  /** Rendered characters inside root before (node, offset). */
  function countUpTo(root, node, offset, isCode) {
    var nodes = textNodes(root), seen = 0, prevSpace = true;
    for (var i = 0; i < nodes.length; i++) {
      var v = nodes[i].nodeValue;
      var end = nodes[i] === node ? offset : v.length;
      for (var j = 0; j < end; j++) {
        var sp = /\s/.test(v[j]);
        if (isCode) seen++;
        else if (sp) { if (!prevSpace) { seen++; prevSpace = true; } }
        else { seen++; prevSpace = false; }
      }
      if (nodes[i] === node) break;
    }
    return seen;
  }

  function caretLineCol(text, pos) {
    var before = text.slice(0, pos);
    var line = (before.match(/\n/g) || []).length;
    return { line: line, col: pos - (before.lastIndexOf("\n") + 1) };
  }

  function rectAt(point) {
    var r = document.createRange();
    r.setStart(point.node, point.offset);
    r.collapse(true);
    var rect = r.getClientRects()[0];
    if ((!rect || (!rect.height && !rect.width)) && point.offset > 0) {
      r.setStart(point.node, point.offset - 1);
      r.setEnd(point.node, point.offset);
      var b = r.getBoundingClientRect();
      rect = { left: b.right, top: b.top, height: b.height };
    }
    return rect || null;
  }

  function hideCaret() { syncCaret.classList.remove("on"); syncCaret.style.opacity = "0"; }

  var caretFrame = 0, caretReveal = false;
  function scheduleCaretSync(reveal) {
    caretReveal = caretReveal || reveal;
    if (caretFrame) return;
    caretFrame = requestAnimationFrame(function () { caretFrame = 0; var r = caretReveal; caretReveal = false; updateCaret(r); });
  }

  /** Editor caret → blinking marker at the same spot in the preview. */
  function updateCaret(reveal) {
    if (!editing) return;
    var text = ta.value;
    var lc = caretLineCol(text, ta.selectionStart);
    var el = blockForLine(lc.line);
    if (!el) { hideCaret(); return; }
    var lines = text.split("\n");
    var isCode = el.tagName === "PRE";
    var start = +el.getAttribute("data-line") + (isCode ? 1 : 0);
    var count;
    if (isCode) {
      if (lc.line < start) count = 0;
      else count = lines.slice(start, lc.line).join("\n").length + (lc.line > start ? 1 : 0) + lc.col;
    } else {
      var parts = [];
      for (var l = start; l < lc.line; l++) parts.push(stripLine(lines[l], false));
      var cur = lines[lc.line] || "";
      var mk = markerLength(cur, false);
      parts.push(lc.col <= mk ? "" : stripInline(cur.slice(mk, lc.col), false));
      count = collapse(parts.join(" ")).length;
    }
    var point = domPointAt(textRoot(el), count, isCode);
    var rect = point && rectAt(point);
    var host = content.getBoundingClientRect();
    if (!rect) {
      var er = el.getBoundingClientRect();
      rect = { left: er.left, top: er.top, height: 20 };
    }
    if (syncCaret.parentNode !== content) content.appendChild(syncCaret);
    var h = Math.max(14, rect.height || 18);
    syncCaret.style.left = (rect.left - host.left) + "px";
    syncCaret.style.top = (rect.top - host.top) + "px";
    syncCaret.style.height = h + "px";
    syncCaret.style.opacity = "";
    syncCaret.classList.remove("on");
    void syncCaret.offsetWidth;
    syncCaret.classList.add("on");

    // Keep it in view.
    var pr = preview.getBoundingClientRect();
    var y = rect.top - pr.top;
    if (reveal || y < 40 || y > preview.clientHeight - 60) {
      if (y < 40 || y > preview.clientHeight - 60) {
        preview.scrollTo({ top: preview.scrollTop + y - preview.clientHeight * 0.38, behavior: "smooth" });
      }
    }
  }

  ["keyup", "mouseup", "focus", "input", "select"].forEach(function (ev) {
    ta.addEventListener(ev, function () { scheduleCaretSync(false); });
  });
  document.addEventListener("selectionchange", function () {
    if (document.activeElement === ta) scheduleCaretSync(false);
  });

  // --- Editor geometry helpers (position of a source offset inside the coloured <pre>) ---

  function editorPoint(offset) {
    var nodes = textNodes(hl), seen = 0;
    for (var i = 0; i < nodes.length; i++) {
      var len = nodes[i].nodeValue.length;
      if (seen + len >= offset) return { node: nodes[i], offset: offset - seen };
      seen += len;
    }
    return nodes.length ? { node: nodes[nodes.length - 1], offset: nodes[nodes.length - 1].nodeValue.length } : null;
  }

  function lineStarts(text) {
    var starts = [0];
    for (var i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) starts.push(i + 1);
    return starts;
  }

  /** Y (viewport) of the top of a source line in the editor. */
  function editorLineTop(starts, line) {
    var p = editorPoint(starts[Math.min(line, starts.length - 1)]);
    var r = p && rectAt(p);
    return r ? r.top : 0;
  }

  function editorLineAtY(starts, y) {
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      var mid = (lo + hi + 1) >> 1;
      if (editorLineTop(starts, mid) <= y) lo = mid; else hi = mid - 1;
    }
    return lo;
  }

  function blockAfter(el) {
    var all = content.querySelectorAll("[data-line]");
    var line = +el.getAttribute("data-line");
    for (var i = 0; i < all.length; i++) if (+all[i].getAttribute("data-line") > line) return all[i];
    return null;
  }

  /** Editor scrolled → align preview so the same source block sits at the top. */
  function syncPreviewToEditor() {
    var starts = lineStarts(ta.value);
    var top = editorPane.getBoundingClientRect().top + 8;
    var line = editorLineAtY(starts, top);
    var el = blockForLine(line);
    if (!el) { syncFrom(editorPane, preview); return; }
    var next = blockAfter(el);
    var l0 = +el.getAttribute("data-line");
    var l1 = next ? +next.getAttribute("data-line") : starts.length;
    var y0 = editorLineTop(starts, l0), y1 = editorLineTop(starts, l1);
    var frac = y1 > y0 ? Math.min(1, Math.max(0, (top - y0) / (y1 - y0))) : 0;
    var er = el.getBoundingClientRect();
    var nextTop = next ? next.getBoundingClientRect().top : er.bottom;
    var target = er.top + frac * (nextTop - er.top);
    preview.scrollTop += target - (preview.getBoundingClientRect().top + 8);
  }

  /** Preview scrolled → align editor to the block at the top of the preview. */
  function syncEditorToPreview() {
    var top = preview.getBoundingClientRect().top + 8;
    var all = content.querySelectorAll("[data-line]");
    var el = null;
    for (var i = 0; i < all.length; i++) {
      var r = all[i].getBoundingClientRect();
      if (r.bottom > top) { el = all[i]; break; }
    }
    if (!el) { syncFrom(preview, editorPane); return; }
    var starts = lineStarts(ta.value);
    var er = el.getBoundingClientRect();
    var next = blockAfter(el);
    var frac = er.height > 0 ? Math.min(1, Math.max(0, (top - er.top) / er.height)) : 0;
    var l0 = +el.getAttribute("data-line");
    var l1 = next ? +next.getAttribute("data-line") : starts.length;
    var y0 = editorLineTop(starts, l0), y1 = editorLineTop(starts, l1);
    var target = y0 + frac * (y1 - y0);
    editorPane.scrollTop += target - (editorPane.getBoundingClientRect().top + 8);
  }

  /** Preview clicked while editing → put the editor caret on the same character. */
  function sourceOffsetFor(el, count, isCode) {
    var text = ta.value, lines = text.split("\n"), starts = lineStarts(text);
    var start = +el.getAttribute("data-line") + (isCode ? 1 : 0);
    if (isCode) {
      var pos = starts[Math.min(start, starts.length - 1)] + count;
      return Math.min(pos, text.length);
    }
    var prev = [];
    for (var l = start; l < Math.min(lines.length, start + 400); l++) {
      var line = lines[l], mk = markerLength(line, false);
      var full = collapse(prev.concat(stripInline(line.slice(mk), false)).join(" ")).length;
      if (full >= count || l === lines.length - 1) {
        for (var k = mk; k <= line.length; k++) {
          var len = collapse(prev.concat(stripInline(line.slice(mk, k), false)).join(" ")).length;
          if (len >= count) return starts[l] + k;
        }
        return starts[l] + line.length;
      }
      prev.push(stripInline(line.slice(mk), false));
    }
    return starts[start] || 0;
  }

  content.addEventListener("click", function (e) {
    if (!editing || e.defaultPrevented) return;
    if (e.target.closest("a, input, summary, button")) return;
    var el = e.target.closest("[data-line]");
    if (!el || !content.contains(el)) return;
    var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(e.clientX, e.clientY) : null;
    var isCode = el.tagName === "PRE";
    var root = textRoot(el);
    var count = range && root.contains(range.startContainer)
      ? countUpTo(root, range.startContainer, range.startOffset, isCode) : 0;
    var pos = sourceOffsetFor(el, count, isCode);
    ta.focus({ preventScroll: true });
    ta.setSelectionRange(pos, pos);
    activePane = editorPane;
    // Bring the caret into view in the editor.
    var pt = editorPoint(pos), r = pt && rectAt(pt);
    if (r) {
      var pr = editorPane.getBoundingClientRect();
      var y = r.top - pr.top;
      if (y < 40 || y > editorPane.clientHeight - 60) {
        editorPane.scrollTo({ top: editorPane.scrollTop + y - editorPane.clientHeight * 0.38, behavior: "smooth" });
      }
    }
    scheduleCaretSync(false);
  });

  // ---------- Theme ----------

  var media = window.matchMedia("(prefers-color-scheme: dark)");

  function effectiveDark() {
    return settings.theme === "dark" || (settings.theme === "auto" && media.matches);
  }

  function applyTheme() {
    root.setAttribute("data-style", settings.style);
    root.setAttribute("data-theme", effectiveDark() ? "dark" : "light");
    root.style.setProperty("--zoom", String(settings.zoom));
    body.classList.toggle("show-toc", !!settings.toc);
    if (settings.toc) body.classList.remove("peek-toc");
    pinBtn.title = settings.toc ? t("unpin") : t("pin");
    if (settings.sidebarTab && !tabRestored) { tabRestored = true; if (settings.sidebarTab !== currentTab) setTab(settings.sidebarTab, true); }
  }

  function postChrome() {
    var bg = getComputedStyle(root).getPropertyValue("--bg").trim();
    postNative({ type: "chrome", bg: bg, dark: effectiveDark() });
  }

  var animTimer = null;
  function configure(next, animate) {
    var visualChange = next.style !== settings.style || next.theme !== settings.theme;
    settings = Object.assign({}, settings, next);
    if (window.MDShell) window.MDShell.setSettings(settings);
    if (next.lang && next.lang !== lang) {
      lang = next.lang;
      root.lang = lang;
      document.getElementById("tab-outline").textContent = t("toc");
      document.getElementById("tab-files").textContent = t("files");
      findInput.placeholder = t("find");
    }
    if (animate && visualChange && document.startViewTransition) {
      document.startViewTransition(applyTheme).updateCallbackDone.then(postChrome, postChrome);
      return;
    } else if (animate && visualChange) {
      body.classList.add("theme-anim");
      applyTheme();
      clearTimeout(animTimer);
      animTimer = setTimeout(function () { body.classList.remove("theme-anim"); }, 400);
    } else {
      applyTheme();
    }
    postChrome();
  }

  media.addEventListener("change", function () {
    if (settings.theme !== "auto") return;
    if (document.startViewTransition) document.startViewTransition(applyTheme).updateCallbackDone.then(postChrome, postChrome);
    else { applyTheme(); postChrome(); }
  });

  // ---------- Find ----------

  var findbar = document.getElementById("findbar");
  var findInput = document.getElementById("find-input");
  var findCount = document.getElementById("find-count");
  var hits = [];
  var hitIndex = -1;

  function clearHits() {
    content.querySelectorAll("mark.find-hit").forEach(function (m) {
      var parent = m.parentNode;
      parent.replaceChild(document.createTextNode(m.textContent), m);
      parent.normalize();
    });
    hits = [];
    hitIndex = -1;
  }

  function runFind(query, quiet) {
    clearHits();
    if (!query) { findCount.textContent = ""; return; }
    var q = query.toLowerCase();
    var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        return n.nodeValue && n.nodeValue.toLowerCase().indexOf(q) >= 0 ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
    });
    var nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(function (node) {
      var text = node.nodeValue, lower = text.toLowerCase();
      var frag = document.createDocumentFragment();
      var pos = 0, idx;
      while ((idx = lower.indexOf(q, pos)) >= 0) {
        if (idx > pos) frag.appendChild(document.createTextNode(text.slice(pos, idx)));
        var mark = document.createElement("mark");
        mark.className = "find-hit";
        mark.textContent = text.slice(idx, idx + q.length);
        frag.appendChild(mark);
        hits.push(mark);
        pos = idx + q.length;
      }
      if (pos < text.length) frag.appendChild(document.createTextNode(text.slice(pos)));
      node.parentNode.replaceChild(frag, node);
    });
    if (hits.length) gotoHit(0, quiet); else findCount.textContent = "0/0";
  }

  function gotoHit(i, quiet) {
    if (!hits.length) return;
    if (hitIndex >= 0 && hits[hitIndex]) hits[hitIndex].classList.remove("current");
    hitIndex = (i + hits.length) % hits.length;
    var m = hits[hitIndex];
    m.classList.add("current");
    if (!quiet) m.scrollIntoView({ block: "center", behavior: "smooth" });
    findCount.textContent = (hitIndex + 1) + "/" + hits.length;
  }

  var findTimer = null;
  findInput.addEventListener("input", function () {
    clearTimeout(findTimer);
    findTimer = setTimeout(function () { runFind(findInput.value); }, 120);
  });
  findInput.addEventListener("keydown", function (e) {
    if (e.key === "Enter") {
      e.preventDefault(); clearTimeout(findTimer);
      if (!hits.length && findInput.value) runFind(findInput.value); else gotoHit(hitIndex + (e.shiftKey ? -1 : 1));
    } else if (e.key === "Escape") { e.preventDefault(); closeFind(); }
  });
  document.getElementById("find-next").onclick = function () { gotoHit(hitIndex + 1); };
  document.getElementById("find-prev").onclick = function () { gotoHit(hitIndex - 1); };
  document.getElementById("find-close").onclick = function () { closeFind(); };

  function openFind() {
    findbar.classList.add("open");
    var sel = String(window.getSelection() || "").trim();
    if (sel && sel.length < 100 && sel.indexOf("\n") < 0) findInput.value = sel;
    findInput.focus();
    findInput.select();
    if (findInput.value) runFind(findInput.value);
  }
  function closeFind() {
    findbar.classList.remove("open");
    clearHits();
    findCount.textContent = "";
    if (editing) editor.focus();
  }
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && findbar.classList.contains("open")) closeFind();
  });

  // ---------- Sidebar: tabs, files, edge peek ----------

  var tocEl = document.getElementById("toc");
  var tabs = document.getElementById("tabs");
  var pinBtn = document.getElementById("pin");
  var views = { outline: document.getElementById("toc-list"), files: document.getElementById("files") };
  var crumbsEl = document.getElementById("crumbs");
  var fileList = document.getElementById("file-list");
  var currentTab = "outline";
  var tabRestored = false;
  var filesLoaded = false;
  var hasNative = !!((window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.native) ||
                     (window.chrome && window.chrome.webview));

  function setTab(name, silent) {
    if (!views[name]) return;
    currentTab = name;
    tabs.dataset.active = name;
    tabs.querySelectorAll(".tab").forEach(function (b) { b.classList.toggle("active", b.dataset.tab === name); });
    Object.keys(views).forEach(function (k) { views[k].classList.toggle("active", k === name); });
    if (name === "files" && !filesLoaded) requestDir(null);
    if (!silent) postNative({ type: "sidebarTab", tab: name });
  }
  tabs.addEventListener("click", function (e) {
    var b = e.target.closest(".tab");
    if (b) setTab(b.dataset.tab);
  });

  function requestDir(path) {
    filesLoaded = true;
    postNative({ type: "listDir", path: path });
  }

  var ICON_DIR = '<svg width="15" height="15" viewBox="0 0 16 16"><path fill="currentColor" d="M1.5 3.5A1.5 1.5 0 0 1 3 2h3.2c.4 0 .8.2 1.1.5L8.4 3.6H13A1.5 1.5 0 0 1 14.5 5v7A1.5 1.5 0 0 1 13 13.5H3A1.5 1.5 0 0 1 1.5 12z"/></svg>';
  var ICON_DOC = '<svg width="15" height="15" viewBox="0 0 16 16"><path fill="none" stroke="currentColor" stroke-width="1.2" d="M4 1.6h5.2L12.4 4.8v9.1a.5.5 0 0 1-.5.5H4a.5.5 0 0 1-.5-.5V2.1a.5.5 0 0 1 .5-.5zM9 1.8v3.2h3.2M5.6 8h4.8M5.6 10.4h3.4"/></svg>';

  function setFiles(data) {
    crumbsEl.innerHTML = "";
    (data.crumbs || []).forEach(function (c, i, all) {
      if (i) {
        var sep = document.createElement("span");
        sep.className = "sep";
        sep.textContent = "›";
        crumbsEl.appendChild(sep);
      }
      var b = document.createElement("button");
      b.textContent = c.name;
      b.title = c.path;
      if (i === all.length - 1) b.className = "here";
      b.onclick = function () { requestDir(c.path); };
      crumbsEl.appendChild(b);
    });
    fileList.innerHTML = "";
    var entries = data.entries || [];
    if (!entries.length) {
      var empty = document.createElement("div");
      empty.className = "toc-empty";
      empty.textContent = t("noFiles");
      fileList.appendChild(empty);
    }
    entries.forEach(function (f) {
      var a = document.createElement("a");
      a.href = "#";
      a.className = (f.dir ? "dir" : "doc") + (f.current ? " current" : "");
      a.title = f.path;
      a.innerHTML = (f.dir ? ICON_DIR : ICON_DOC) + '<span class="name"></span>';
      a.querySelector(".name").textContent = f.name;
      a.onclick = function (e) {
        e.preventDefault();
        if (f.dir) requestDir(f.path);
        else if (!f.current) postNative({ type: "openFile", path: f.path, newWindow: e.metaKey || e.ctrlKey });
      };
      fileList.appendChild(a);
    });
    fileList.classList.remove("swap");
    void fileList.offsetWidth;
    fileList.classList.add("swap");
    var cur = fileList.querySelector(".current");
    if (cur) cur.scrollIntoView({ block: "nearest" });
  }

  function pinned() { return !!settings.toc && !editing; }

  function pinTOC(value) {
    clearTimeout(hideTimer);
    if (value && editing) setMode(false);
    configure({ toc: value }, false);
    postNative({ type: "pinTOC", value: value });
  }
  pinBtn.addEventListener("click", function () { pinTOC(!pinned()); });

  var edge = document.getElementById("edge-zone");
  var handle = document.getElementById("edge-handle");
  var peekTimer = null, hideTimer = null;

  function openPeek() { clearTimeout(hideTimer); hideTimer = null; body.classList.add("peek-toc"); updateActive(); }
  function closePeek() { clearTimeout(hideTimer); hideTimer = null; body.classList.remove("peek-toc"); }
  function peeking() { return body.classList.contains("peek-toc") && !pinned(); }
  function scheduleHide() {
    if (hideTimer) return;                       // already counting down
    hideTimer = setTimeout(function () { hideTimer = null; if (peeking()) closePeek(); }, 3000);
  }
  function cancelHide() { clearTimeout(hideTimer); hideTimer = null; }

  /** Decide from where the pointer is, not from enter/leave events (those get lost on fast moves). */
  function trackPointer(x, y) {
    if (!peeking()) return;
    var r = tocEl.getBoundingClientRect();
    var inside = x >= 0 && y >= 0 && x <= r.right + 6 && y <= window.innerHeight;
    if (inside) cancelHide(); else scheduleHide();
  }

  edge.addEventListener("mousemove", function (e) { handle.style.top = e.clientY + "px"; });
  edge.addEventListener("mouseenter", function (e) {
    handle.style.top = e.clientY + "px";
    clearTimeout(peekTimer);
    if (!peeking()) peekTimer = setTimeout(openPeek, 160);
  });
  edge.addEventListener("mouseleave", function () { clearTimeout(peekTimer); });
  edge.addEventListener("click", function () { pinTOC(true); });
  document.addEventListener("mousemove", function (e) { trackPointer(e.clientX, e.clientY); }, { passive: true });
  // Pointer left the window, or the window lost focus: start the countdown too.
  document.documentElement.addEventListener("mouseleave", function () { if (peeking()) scheduleHide(); });
  window.addEventListener("blur", function () { if (peeking()) scheduleHide(); });

  // ---------- Toast ----------

  var toastTimer = null;
  function toast(msg) {
    toastEl.textContent = msg;
    toastEl.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.remove("show"); }, 2200);
  }

  // ---------- Public API ----------

  window.MDReader = {
    /** Render markdown from disk. base = file URL of the document (for relative links). */
    render: function (md, base, keepScroll) {
      baseURL = base || null;
      editor.setValue(String(md || ""));
      if (!keepScroll) { filesLoaded = false; if (currentTab === "files") requestDir(null); }
      var n = renderMarkdown(md, keepScroll, firstRender || !keepScroll);
      firstRender = false;
      return n;
    },
    configure: configure,
    setMode: setMode,
    toggleMode: function () { return setMode(!editing); },
    togglePin: function () { pinTOC(!pinned()); },
    isEditing: function () { return editing; },
    source: function () { return editor.value(); },
    flush: flushEdits,
    toast: toast,
    setFiles: setFiles,
    setTab: setTab,
    find: function () { if (editing) { setMode(false); setTimeout(openFind, 200); } else openFind(); },
    findNext: function () { if (!hits.length) openFind(); else gotoHit(hitIndex + 1); },
    findPrevious: function () { if (!hits.length) openFind(); else gotoHit(hitIndex - 1); },
    scrollToHeading: function (text) {
      var match = tocLinks.filter(function (l) { return l.textContent.trim() === String(text).trim(); })[0];
      if (match) scrollToId(match.dataset.target);
    }
  };

  applyTheme();
  postNative({ type: "ready" });
})();

/*
 * In-page toolbar for hosts without a native title bar (Windows / WebView2).
 * Active only when the host sets window.MDHost = "win" before the page loads.
 * Host → page: MDShell.setTitle(name, edited)
 * Page → host: {type:"command", name:"open"|"new"|"save"|"print"|"exportPdf"|"openExternal"}
 *              {type:"setting", key, value}
 */
(function () {
  "use strict";
  if (window.MDHost !== "win") return;

  var body = document.body;
  var settings = { style: "github", theme: "auto", zoom: 1 };
  var lang = (navigator.language || "zh").toLowerCase().indexOf("zh") === 0 ? "zh" : "en";
  var T = {
    zh: { toc: "目录", open: "打开 (Ctrl+O)", edit: "编辑 (Ctrl+E)", read: "返回阅读 (Ctrl+E)", look: "风格与外观",
          style: "风格", appearance: "外观", size: "字号", auto: "自动", light: "浅色", dark: "深色", academic: "学术" },
    en: { toc: "Contents", open: "Open (Ctrl+O)", edit: "Edit (Ctrl+E)", read: "Back to reading (Ctrl+E)", look: "Style & appearance",
          style: "Style", appearance: "Appearance", size: "Text size", auto: "Auto", light: "Light", dark: "Dark", academic: "Academic" }
  };
  function t(k) { return T[lang][k]; }

  function post(msg) { try { window.chrome.webview.postMessage(msg); } catch (e) { /* ignore */ } }

  var ICON = {
    toc: '<svg width="18" height="18" viewBox="0 0 20 20"><rect x="2.5" y="3.5" width="15" height="13" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M7.5 3.8v12.4M4.4 7h1.4M4.4 9.5h1.4M4.4 12h1.4" stroke="currentColor" stroke-width="1.3"/></svg>',
    open: '<svg width="18" height="18" viewBox="0 0 20 20"><path fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round" d="M2.8 5.2c0-.9.7-1.6 1.6-1.6h3.4l1.6 1.8h6.2c.9 0 1.6.7 1.6 1.6v7.4c0 .9-.7 1.6-1.6 1.6H4.4c-.9 0-1.6-.7-1.6-1.6z"/></svg>',
    edit: '<svg width="18" height="18" viewBox="0 0 20 20"><path fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round" d="M10 4H5.2A1.7 1.7 0 0 0 3.5 5.7v9.1c0 .9.8 1.7 1.7 1.7h9.1c.9 0 1.7-.8 1.7-1.7V10M14.6 3.2l2.2 2.2-7.3 7.3-2.9.7.7-2.9z"/></svg>',
    look: '<svg width="18" height="18" viewBox="0 0 20 20"><path fill="none" stroke="currentColor" stroke-width="1.4" d="M10 2.8a7.2 7.2 0 1 0 0 14.4c1 0 1.5-.6 1.5-1.3 0-.9-.8-1.2-.8-2 0-.8.6-1.3 1.4-1.3h1.7a3.4 3.4 0 0 0 3.4-3.4C17.2 5.6 14 2.8 10 2.8z"/><circle cx="6.4" cy="9" r="1.1" fill="currentColor"/><circle cx="8.8" cy="6.1" r="1.1" fill="currentColor"/><circle cx="12.4" cy="6.4" r="1.1" fill="currentColor"/></svg>'
  };

  // ---------- Toolbar ----------

  var bar = document.createElement("div");
  bar.className = "host-bar";
  bar.innerHTML =
    '<button class="hb-btn" id="hb-toc">' + ICON.toc + '</button>' +
    '<button class="hb-btn" id="hb-open">' + ICON.open + '</button>' +
    '<div class="hb-title" id="hb-title"><span class="name"></span><span class="dot"></span></div>' +
    '<button class="hb-btn" id="hb-edit">' + ICON.edit + '</button>' +
    '<button class="hb-btn" id="hb-look">' + ICON.look + '</button>';
  body.appendChild(bar);
  body.classList.add("host-bar-on");

  var btnToc = bar.querySelector("#hb-toc"), btnEdit = bar.querySelector("#hb-edit"), btnLook = bar.querySelector("#hb-look");
  btnToc.title = t("toc");
  bar.querySelector("#hb-open").title = t("open");
  btnLook.title = t("look");
  btnToc.onclick = function () { MDReader.togglePin(); };
  bar.querySelector("#hb-open").onclick = function () { post({ type: "command", name: "open" }); };
  btnEdit.onclick = function () { MDReader.toggleMode(); };
  btnLook.onclick = function (e) { e.stopPropagation(); togglePop(); };

  function syncButtons() {
    var editing = body.classList.contains("editing");
    btnEdit.classList.toggle("on", editing);
    btnEdit.title = editing ? t("read") : t("edit");
    btnToc.classList.toggle("on", body.classList.contains("show-toc") && !editing);
  }
  new MutationObserver(syncButtons).observe(body, { attributes: true, attributeFilter: ["class"] });
  syncButtons();

  // Hairline under the bar once the preview scrolls.
  ["preview-pane", "editor-pane"].forEach(function (id) {
    var p = document.getElementById(id);
    if (p) p.addEventListener("scroll", function () { bar.classList.toggle("scrolled", p.scrollTop > 4); }, { passive: true });
  });

  // ---------- Style popover ----------

  var pop = document.createElement("div");
  pop.className = "hb-pop";
  var styles = [["github", "GitHub"], ["notion", "Notion"], ["academic", t("academic")], ["nord", "Nord"]];
  pop.innerHTML =
    "<h4>" + t("style") + '</h4><div class="hb-cards">' +
    styles.map(function (s) {
      return '<button class="hb-card" data-style="' + s[0] + '"><span class="sw sw-' + s[0] +
        '"><span class="aa">Aa</span><span class="ln"></span><span class="ln"></span></span>' + s[1] + "</button>";
    }).join("") + "</div>" +
    "<h4>" + t("appearance") + '</h4><div class="hb-seg">' +
    [["auto", t("auto")], ["light", t("light")], ["dark", t("dark")]].map(function (m) {
      return '<button data-theme="' + m[0] + '">' + m[1] + "</button>";
    }).join("") + "</div>" +
    "<h4>" + t("size") + '</h4><div class="hb-size"><button class="hb-btn" data-zoom="-">A−</button>' +
    '<span class="zoom" id="hb-zoom">100%</span><button class="hb-btn" data-zoom="+">A+</button></div>';
  body.appendChild(pop);

  function set(key, value) {
    settings[key] = value;
    var patch = {};
    patch[key] = value;
    MDReader.configure(patch, true);
    post({ type: "setting", key: key, value: value });
    syncPop();
  }
  function syncPop() {
    pop.querySelectorAll(".hb-card").forEach(function (c) { c.classList.toggle("on", c.dataset.style === settings.style); });
    pop.querySelectorAll(".hb-seg button").forEach(function (b) { b.classList.toggle("on", b.dataset.theme === settings.theme); });
    pop.querySelector("#hb-zoom").textContent = Math.round(settings.zoom * 100) + "%";
  }
  pop.addEventListener("click", function (e) {
    e.stopPropagation();
    var card = e.target.closest(".hb-card");
    if (card) return set("style", card.dataset.style);
    var seg = e.target.closest("[data-theme]");
    if (seg) return set("theme", seg.dataset.theme);
    var z = e.target.closest("[data-zoom]");
    if (z) return set("zoom", Math.min(2.4, Math.max(0.6, Math.round(settings.zoom * (z.dataset.zoom === "+" ? 1.1 : 1 / 1.1) * 100) / 100)));
    if (e.target.id === "hb-zoom") return set("zoom", 1);
  });
  function togglePop(force) {
    var open = force != null ? force : !pop.classList.contains("open");
    pop.classList.toggle("open", open);
    btnLook.classList.toggle("on", open);
    if (open) syncPop();
  }
  document.addEventListener("click", function () { togglePop(false); });

  // ---------- Keyboard shortcuts (browser accelerators are disabled by the host) ----------

  document.addEventListener("keydown", function (e) {
    if (!(e.ctrlKey || e.metaKey) || e.altKey) {
      if (e.key === "Escape") togglePop(false);
      return;
    }
    var k = e.key.toLowerCase(), handled = true;
    if (k === "o") post({ type: "command", name: "open" });
    else if (k === "n") post({ type: "command", name: "new" });
    else if (k === "s") post({ type: "command", name: "save" });
    else if (k === "p") post({ type: "command", name: "print" });
    else if (k === "e" && e.shiftKey) post({ type: "command", name: "exportPdf" });
    else if (k === "e") MDReader.toggleMode();
    else if (k === "f") MDReader.find();
    else if (k === "g") { if (e.shiftKey) MDReader.findPrevious(); else MDReader.findNext(); }
    else if (k === "=" || k === "+") set("zoom", Math.min(2.4, Math.round(settings.zoom * 110) / 100));
    else if (k === "-") set("zoom", Math.max(0.6, Math.round(settings.zoom / 1.1 * 100) / 100));
    else if (k === "0") set("zoom", 1);
    else if (k === "\\") MDReader.togglePin();
    else handled = false;
    if (handled) e.preventDefault();
  }, true);

  window.MDShell = {
    setTitle: function (name, edited) {
      var el = document.getElementById("hb-title");
      el.querySelector(".name").textContent = name || "";
      el.classList.toggle("edited", !!edited);
    },
    setSettings: function (s) { settings = Object.assign(settings, s || {}); syncPop(); }
  };
})();

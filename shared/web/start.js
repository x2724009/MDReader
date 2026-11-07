/*
 * Start page controller.
 * Native → page: MDStart.configure(settings), MDStart.setRecents([{name, dir, path, modified}]), MDStart.setVersion(v)
 * Page → native: {type:"ready"} {type:"open"} {type:"new"} {type:"openRecent", path} {type:"clearRecents"}
 */
(function () {
  "use strict";

  var root = document.documentElement;
  var list = document.getElementById("recent-list");
  var lang = "zh";
  var settings = { style: "github", theme: "auto" };
  var media = window.matchMedia("(prefers-color-scheme: dark)");

  var T = {
    zh: { tagline: "轻量的 Markdown 阅读器", open: "打开文件…", "new": "新建文档", recent: "最近打开", clear: "清除",
          drop: "也可以把 .md 文件拖到这里", release: "松开以打开", empty: "还没有最近打开的文件",
          now: "刚刚", min: " 分钟前", hour: " 小时前", day: " 天前", yesterday: "昨天", version: "版本 " },
    en: { tagline: "A lightweight Markdown reader", open: "Open File…", "new": "New Document", recent: "Recent", clear: "Clear",
          drop: "Or drop a .md file here", release: "Release to open", empty: "No recent files yet",
          now: "Just now", min: " min ago", hour: " h ago", day: " d ago", yesterday: "Yesterday", version: "Version " }
  };
  function t(k) { return (T[lang] || T.en)[k]; }

  function post(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.native) {
        window.webkit.messageHandlers.native.postMessage(msg);
      } else if (window.chrome && window.chrome.webview) {
        window.chrome.webview.postMessage(msg);
      }
    } catch (e) { /* ignore */ }
  }

  function applyTexts() {
    root.lang = lang;
    document.getElementById("tagline").textContent = t("tagline");
    document.getElementById("lbl-open").textContent = t("open");
    document.getElementById("lbl-new").textContent = t("new");
    document.getElementById("lbl-recent").textContent = t("recent");
    document.getElementById("act-clear").textContent = t("clear");
    document.getElementById("drop-hint").textContent = t("drop");
    document.getElementById("drop-card").textContent = t("release");
  }

  function applyTheme() {
    var dark = settings.theme === "dark" || (settings.theme === "auto" && media.matches);
    root.setAttribute("data-style", settings.style || "github");
    root.setAttribute("data-theme", dark ? "dark" : "light");
    var bg = getComputedStyle(root).getPropertyValue("--bg").trim();
    post({ type: "chrome", bg: bg, dark: dark });
  }

  media.addEventListener("change", function () { if (settings.theme === "auto") applyTheme(); });

  function relTime(ms) {
    if (!ms) return "";
    var diff = (Date.now() - ms) / 1000;
    if (diff < 60) return t("now");
    if (diff < 3600) return Math.floor(diff / 60) + t("min");
    if (diff < 86400) return Math.floor(diff / 3600) + t("hour");
    if (diff < 172800) return t("yesterday");
    if (diff < 7 * 86400) return Math.floor(diff / 86400) + t("day");
    var d = new Date(ms);
    return d.getFullYear() === new Date().getFullYear()
      ? (d.getMonth() + 1) + "/" + d.getDate()
      : d.getFullYear() + "/" + (d.getMonth() + 1) + "/" + d.getDate();
  }

  var DOC_SVG = 'data:image/svg+xml;utf8,' + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 30 36"><path d="M3 1h16l8 8v24a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V3a2 2 0 0 1 2-2z" fill="#fff" stroke="#d6d9e0"/>' +
    '<path d="M19 1v8h8" fill="#e8e8f6" stroke="#d6d9e0"/><rect x="5" y="22" width="20" height="9" rx="2.5" fill="#5b4be0"/>' +
    '<path d="M8.4 29V24.6l1.6 2 1.6-2V29M15.2 24.4v4.2m-1.6-1.4 1.6 1.6 1.6-1.6" stroke="#fff" stroke-width="1.1" fill="none" stroke-linecap="round" stroke-linejoin="round"/>' +
    '<rect x="5" y="8" width="9" height="2" rx="1" fill="#2b2f36"/><rect x="5" y="13" width="15" height="1.6" rx=".8" fill="#dadde3"/><rect x="5" y="17" width="12" height="1.6" rx=".8" fill="#dadde3"/></svg>');

  function setRecents(items) {
    list.innerHTML = "";
    if (!items || !items.length) {
      var empty = document.createElement("div");
      empty.className = "empty";
      empty.innerHTML = '<svg width="44" height="44" viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.3" d="M7 3h7l4 4v13a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM14 3v4h4M9 12h6M9 15.5h4"/></svg><span></span>';
      empty.querySelector("span").textContent = t("empty");
      list.appendChild(empty);
      document.getElementById("act-clear").style.display = "none";
      return;
    }
    document.getElementById("act-clear").style.display = "";
    items.forEach(function (it, i) {
      var b = document.createElement("button");
      b.className = "recent";
      b.style.animationDelay = (0.12 + Math.min(i, 10) * 0.03) + "s";
      b.title = it.path;
      b.innerHTML = '<img class="doc" alt=""><span class="meta"><span class="name"></span><span class="path"></span></span><span class="when"></span>';
      b.querySelector(".doc").src = DOC_SVG;
      b.querySelector(".name").textContent = it.name;
      // RTL keeps the tail visible; wrap in LRM marks so punctuation stays put.
      b.querySelector(".path").textContent = "‎" + it.dir + "‎";
      b.querySelector(".when").textContent = relTime(it.modified);
      b.onclick = function () { post({ type: "openRecent", path: it.path }); };
      list.appendChild(b);
    });
  }

  document.getElementById("act-open").onclick = function () { post({ type: "open" }); };
  document.getElementById("act-new").onclick = function () { post({ type: "new" }); };
  document.getElementById("act-clear").onclick = function () { post({ type: "clearRecents" }); };

  // Drag & drop: show the overlay; the drop itself is handled natively (WebKit navigates to the file).
  var depth = 0;
  document.addEventListener("dragenter", function () { depth++; document.body.classList.add("dragging"); });
  document.addEventListener("dragleave", function () { depth = Math.max(0, depth - 1); if (!depth) document.body.classList.remove("dragging"); });
  document.addEventListener("drop", function () { depth = 0; document.body.classList.remove("dragging"); });

  // Keyboard: ↑/↓ through recents, Enter to open.
  document.addEventListener("keydown", function (e) {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    var items = Array.prototype.slice.call(list.querySelectorAll(".recent"));
    if (!items.length) return;
    e.preventDefault();
    var i = items.indexOf(document.activeElement);
    i = e.key === "ArrowDown" ? Math.min(items.length - 1, i + 1) : Math.max(0, i - 1);
    items[i].focus();
  });

  window.MDStart = {
    configure: function (s) {
      settings = Object.assign({}, settings, s || {});
      if (s && s.lang && s.lang !== lang) { lang = s.lang; applyTexts(); }
      applyTheme();
    },
    setRecents: setRecents,
    setVersion: function (v) { document.getElementById("version").textContent = v ? t("version") + v : ""; }
  };

  applyTexts();
  applyTheme();
  setRecents([]);
  post({ type: "ready" });
})();

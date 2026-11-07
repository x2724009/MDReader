/*
 * MDReader render core — shared by the macOS app, the Quick Look preview
 * (runs inside JavaScriptCore, no DOM) and the Windows app (WebView2).
 * Depends on globals: marked, hljs.
 */
(function (g) {
  "use strict";

  function escapeHTML(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function slugify(text, used) {
    var base = String(text)
      .trim()
      .toLowerCase()
      .replace(/<[^>]*>/g, "")
      .replace(/[^\p{L}\p{N}\s_-]/gu, "")
      .replace(/\s+/g, "-") || "section";
    var slug = base;
    var n = 1;
    while (used[slug]) slug = base + "-" + n++;
    used[slug] = true;
    return slug;
  }

  // ---------- Front matter → properties ----------

  function splitFrontMatter(md) {
    var m = /^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(md);
    if (!m) return { body: md, front: null };
    return { body: md.slice(m[0].length), front: m[1] };
  }

  function unquote(s) {
    s = String(s).trim();
    if ((s[0] === '"' && s[s.length - 1] === '"') || (s[0] === "'" && s[s.length - 1] === "'")) s = s.slice(1, -1);
    return s;
  }

  function parseProps(src) {
    var props = [];
    var cur = null;
    src.split(/\r?\n/).forEach(function (line) {
      var m;
      if ((m = /^([^\s:#-][^:]*):\s*(.*)$/.exec(line))) {
        cur = { k: m[1].trim(), v: m[2].trim(), list: null };
        if (/^\[.*\]$/.test(cur.v)) {
          cur.list = cur.v.slice(1, -1).split(",").map(unquote).filter(Boolean);
        }
        props.push(cur);
      } else if ((m = /^\s+-\s+(.*)$/.exec(line)) && cur) {
        (cur.list = cur.list || []).push(unquote(m[1]));
      } else if (cur && /^\s+\S/.test(line) && !cur.list) {
        cur.v += " " + line.trim();
      }
    });
    return props;
  }

  function renderProps(src) {
    var props = parseProps(src);
    if (!props.length) {
      return '<details class="props"><summary>Front matter</summary><pre><code>' + escapeHTML(src) + "</code></pre></details>\n";
    }
    var rows = props.map(function (p) {
      var v;
      if (p.list) {
        v = p.list.map(function (x) { return '<span class="chip">' + escapeHTML(x) + "</span>"; }).join("");
      } else {
        v = escapeHTML(unquote(p.v));
      }
      return '<div class="row"><span class="k">' + escapeHTML(p.k) + '</span><span class="v">' + v + "</span></div>";
    });
    return '<div class="props">' + rows.join("") + "</div>\n";
  }

  // ---------- Obsidian-isms ----------

  /** Pipes inside [[a|b]] would split GFM table cells: escape them on table rows (outside code fences). */
  function protectWikiPipes(md) {
    var lines = md.split("\n");
    var fence = null;
    for (var i = 0; i < lines.length; i++) {
      var t = lines[i].replace(/^\s+/, "");
      var f = /^(```|~~~)/.exec(t);
      if (f) {
        if (!fence) fence = f[1]; else if (t.indexOf(fence) === 0) fence = null;
        continue;
      }
      if (fence || lines[i].indexOf("|") < 0 || lines[i].indexOf("[[") < 0) continue;
      lines[i] = lines[i].replace(/\[\[[^\]\n]*\]\]/g, function (w) { return w.replace(/(^|[^\\])\|/g, "$1\\|"); });
    }
    return lines.join("\n");
  }

  var wikilink = {
    name: "wikilink",
    level: "inline",
    start: function (src) { var i = src.indexOf("[["); return i < 0 ? undefined : (i > 0 && src[i - 1] === "!" ? i - 1 : i); },
    tokenizer: function (src) {
      var m = /^(!?)\[\[([^\]\n]+?)\]\]/.exec(src);
      if (!m) return undefined;
      var inner = m[2].replace(/\\\|/g, "|");
      var bar = inner.indexOf("|");
      var target = (bar >= 0 ? inner.slice(0, bar) : inner).trim();
      var alias = bar >= 0 ? inner.slice(bar + 1).trim() : "";
      var hash = target.indexOf("#");
      var heading = hash >= 0 ? target.slice(hash + 1) : "";
      var path = hash >= 0 ? target.slice(0, hash) : target;
      return { type: "wikilink", raw: m[0], embed: m[1] === "!", path: path, heading: heading, alias: alias };
    },
    renderer: function (t) {
      var label = t.alias || (t.path ? t.path.split("/").pop() : "") + (t.heading ? " › " + t.heading : "");
      if (t.embed && /\.(png|jpe?g|gif|webp|svg|avif|bmp)$/i.test(t.path)) {
        return '<img data-wikilink="' + escapeHTML(t.path) + '" alt="' + escapeHTML(t.alias || t.path) + '">';
      }
      return '<a class="wikilink" href="#" data-wikilink="' + escapeHTML(t.path) + '" data-heading="' +
        escapeHTML(t.heading) + '">' + escapeHTML(label || t.heading) + "</a>";
    }
  };

  var highlightMark = {
    name: "mark",
    level: "inline",
    start: function (src) { var i = src.indexOf("=="); return i < 0 ? undefined : i; },
    tokenizer: function (src) {
      var m = /^==(?=\S)([^\n]*?\S)==/.exec(src);
      if (!m) return undefined;
      return { type: "mark", raw: m[0], tokens: this.lexer.inlineTokens(m[1]) };
    },
    renderer: function (t) { return "<mark>" + this.parser.parseInline(t.tokens) + "</mark>"; }
  };

  var CALLOUT_NAMES = {
    note: "Note", info: "Info", tip: "Tip", hint: "Tip", success: "Success", check: "Success", done: "Done",
    question: "Question", help: "Question", faq: "FAQ", warning: "Warning", caution: "Caution", attention: "Attention",
    danger: "Danger", error: "Error", bug: "Bug", failure: "Failure", fail: "Failure", important: "Important",
    example: "Example", quote: "Quote", cite: "Quote", abstract: "Summary", summary: "Summary", tldr: "TL;DR", todo: "Todo"
  };

  function highlight(code, lang) {
    if (typeof hljs === "undefined") return null;
    lang = (lang || "").trim().split(/\s+/)[0].toLowerCase();
    if (!lang || lang === "text" || lang === "plain" || lang === "txt") return null;
    if (!hljs.getLanguage(lang)) return null;
    try {
      return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
    } catch (e) {
      return null;
    }
  }

  // ---------- Source line mapping (data-line on block elements) ----------

  function countLines(str) {
    var n = 0;
    for (var i = 0; i < str.length; i++) if (str.charCodeAt(i) === 10) n++;
    return n;
  }

  /** Give every block token (and list item) the 0-based source line it starts on. */
  function annotate(tokens, line) {
    (tokens || []).forEach(function (tk) {
      tk._line = line;
      if (tk.type === "list") {
        var l = line;
        tk.items.forEach(function (item) {
          item._line = l;
          annotate(item.tokens, l);
          l += countLines(item.raw);
        });
      } else if (tk.type === "blockquote") {
        annotate(tk.tokens, line);
      }
      line += countLines(tk.raw || "");
    });
  }

  function withLine(html, line) {
    if (line == null) return html;
    return html.replace(/^(\s*<[a-zA-Z][a-zA-Z0-9-]*)/, '$1 data-line="' + line + '"');
  }

  /**
   * Convert markdown to HTML.
   * Returns { html, headings: [{depth, text, id}], front }
   */
  function toHTML(md) {
    var parts = splitFrontMatter(String(md || ""));
    var used = {};
    var headings = [];

    var renderer = {
      heading: function (token) {
        var inner = this.parser.parseInline(token.tokens);
        var plain = inner.replace(/<[^>]*>/g, "").replace(/&amp;/g, "&").replace(/&lt;/g, "<")
          .replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'");
        var id = slugify(plain, used);
        headings.push({ depth: token.depth, text: plain, id: id });
        return '<h' + token.depth + ' id="' + escapeHTML(id) + '"' +
          (token._line != null ? ' data-line="' + token._line + '"' : "") + ">" +
          '<a class="anchor" href="#' + escapeHTML(id) + '" aria-hidden="true"></a>' +
          inner + '</h' + token.depth + '>\n';
      },
      code: function (token) {
        var lang = (token.lang || "").trim().split(/\s+/)[0];
        var text = token.text.replace(/\n$/, "");
        var hl = highlight(text, lang);
        var body = hl != null ? hl : escapeHTML(text);
        var label = lang ? '<span class="code-lang">' + escapeHTML(lang) + '</span>' : "";
        return '<pre class="code-block' + (lang ? " lang-" + escapeHTML(lang.toLowerCase()) : "") + '"' +
          (token._line != null ? ' data-line="' + token._line + '"' : "") + ">" + label +
          '<code class="hljs">' + body + '</code></pre>\n';
      },
      blockquote: function (token) {
        var body = this.parser.parse(token.tokens);
        var m = /^<p(?: data-line="\d+")?>\[!([A-Za-z]+)\][+-]?[ \t]*([^\n<]*)(?:\n|<\/p>\n?)/.exec(body);
        if (!m) return withLine("<blockquote>\n" + body + "</blockquote>\n", token._line);
        var kind = m[1].toLowerCase();
        var title = m[2].trim() || CALLOUT_NAMES[kind] || (kind.charAt(0).toUpperCase() + kind.slice(1));
        var rest = body.slice(m[0].length);
        if (m[0].slice(-1) === "\n" && !/<\/p>\n?$/.test(m[0])) rest = "<p>" + rest;
        return '<div class="callout ' + escapeHTML(kind) + '"' + (token._line != null ? ' data-line="' + token._line + '"' : "") + '><div class="callout-title">' + title + "</div>" + rest + "</div>\n";
      }
    };

    // Default renderers, tagged with their source line.
    var base = marked.Renderer.prototype;
    ["paragraph", "hr", "html", "listitem"].forEach(function (type) {
      renderer[type] = function (token) {
        var out = base[type].call(this, token);
        return token.block === false ? out : withLine(out, token._line);
      };
    });
    renderer.list = function (token) { return withLine(base.list.call(this, token), token._line); };
    renderer.table = function (token) {
      var out = base.table.call(this, token);
      if (token._line == null) return out;
      var row = 0;
      out = out.replace(/<tr>/g, function () {
        var line = token._line + (row === 0 ? 0 : row + 1);   // header, separator, then one line per row
        row++;
        return '<tr data-line="' + line + '">';
      });
      return withLine(out, token._line);
    };

    var parser = new marked.Marked({ gfm: true, breaks: false });
    parser.use({ renderer: renderer, extensions: [wikilink, highlightMark] });

    var html = "";
    var frontLines = 0;
    if (parts.front != null) {
      html += renderProps(parts.front);
      frontLines = countLines(String(md).slice(0, String(md).length - parts.body.length));
    }
    var tokens = parser.lexer(protectWikiPipes(parts.body));
    annotate(tokens, frontLines);
    html += parser.parser(tokens);
    return { html: html, headings: headings, front: parts.front };
  }

  g.MDCore = { toHTML: toHTML, escapeHTML: escapeHTML };
})(typeof globalThis !== "undefined" ? globalThis : this);

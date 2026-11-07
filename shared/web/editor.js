/*
 * MDEditor — a lightweight Markdown source editor: a transparent <textarea>
 * over a syntax-coloured <pre>. Keeps native undo by editing through
 * document.execCommand("insertText").
 */
(function (g) {
  "use strict";

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function inline(s) { // s is already escaped
    return s
      .replace(/(`+)([^`]+?)\1/g, '<span class="t-icode">$&</span>')
      .replace(/(\*\*|__)(?=\S)(.+?\S)\1/g, '<span class="t-bold">$&</span>')
      .replace(/!?\[\[[^\]]+\]\]/g, '<span class="t-link">$&</span>')
      .replace(/!?\[[^\]\n]*\]\([^)\n]*\)/g, '<span class="t-link">$&</span>');
  }

  function highlight(src) {
    var lines = src.split("\n");
    var out = [];
    var fence = null;
    var front = lines[0] === "---";
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var e = esc(line);
      if (front) {
        out.push('<span class="t-front">' + e + "</span>");
        if (i > 0 && (line === "---" || line === "...")) front = false;
        continue;
      }
      var t = line.replace(/^\s+/, "");
      var f = /^(```|~~~)/.exec(t);
      if (f) {
        if (!fence) fence = f[1]; else if (t.indexOf(fence) === 0) fence = null;
        out.push('<span class="t-fence">' + e + "</span>");
        continue;
      }
      if (fence) { out.push('<span class="t-code">' + e + "</span>"); continue; }
      var m;
      if ((m = /^(#{1,6})(\s.*)?$/.exec(line))) {
        out.push('<span class="t-hmark">' + m[1] + '</span><span class="t-h">' + inline(esc(m[2] || "")) + "</span>");
      } else if (/^\s*>/.test(line)) {
        out.push('<span class="t-quote">' + inline(e) + "</span>");
      } else if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) {
        out.push('<span class="t-hr">' + e + "</span>");
      } else if ((m = /^(\s*)([-*+]|\d+[.)])(\s+)(\[[ xX]\]\s)?(.*)$/.exec(line))) {
        out.push(m[1] + '<span class="t-list">' + esc(m[2]) + "</span>" + m[3] +
          (m[4] ? '<span class="t-task">' + esc(m[4]) + "</span>" : "") + inline(esc(m[5])));
      } else if (/^\s*\|/.test(line)) {
        out.push(inline(e).replace(/\|(?![^<]*>)/g, '<span class="t-pipe">|</span>'));
      } else {
        out.push(inline(e));
      }
    }
    // Trailing newline needs a character to keep the heights in sync.
    return out.join("\n") + "\n ";
  }

  function MDEditor(textarea, hl, onChange) {
    this.ta = textarea;
    this.hl = hl;
    this.onChange = onChange;
    this.frame = 0;
    var self = this;
    textarea.addEventListener("input", function () { self.refresh(); self.onChange(self.ta.value); });
    textarea.addEventListener("keydown", function (e) { self.keydown(e); });
  }

  MDEditor.prototype.refresh = function () {
    var self = this;
    if (this.frame) return;
    this.frame = requestAnimationFrame(function () {
      self.frame = 0;
      self.hl.innerHTML = highlight(self.ta.value);
    });
  };

  MDEditor.prototype.setValue = function (text) {
    if (this.ta.value === text) return;
    var pos = Math.min(this.ta.selectionStart, text.length);
    this.ta.value = text;
    this.ta.setSelectionRange(pos, pos);
    this.hl.innerHTML = highlight(text);
  };

  MDEditor.prototype.value = function () { return this.ta.value; };
  MDEditor.prototype.focus = function () { this.ta.focus({ preventScroll: true }); };

  /** Replace [start, end) with text, keeping native undo. */
  MDEditor.prototype.replace = function (start, end, text, selStart, selEnd) {
    var ta = this.ta;
    ta.focus({ preventScroll: true });
    ta.setSelectionRange(start, end);
    var ok = false;
    try { ok = document.execCommand("insertText", false, text); } catch (e) { ok = false; }
    if (!ok) {
      ta.setRangeText(text, start, end, "end");
      ta.dispatchEvent(new Event("input"));
    }
    if (selStart != null) ta.setSelectionRange(selStart, selEnd != null ? selEnd : selStart);
  };

  MDEditor.prototype.lineBounds = function (pos) {
    var v = this.ta.value;
    var s = v.lastIndexOf("\n", pos - 1) + 1;
    var e = v.indexOf("\n", pos);
    if (e < 0) e = v.length;
    return [s, e];
  };

  MDEditor.prototype.wrap = function (before, after, placeholder) {
    var ta = this.ta, s = ta.selectionStart, e = ta.selectionEnd;
    var sel = ta.value.slice(s, e);
    if (sel && sel.slice(0, before.length) === before && sel.slice(-after.length) === after) {
      var inner = sel.slice(before.length, sel.length - after.length);
      this.replace(s, e, inner, s, s + inner.length);
      return;
    }
    var text = sel || placeholder || "";
    this.replace(s, e, before + text + after, s + before.length, s + before.length + text.length);
  };

  MDEditor.prototype.indent = function (outdent) {
    var ta = this.ta, v = ta.value;
    var s = ta.selectionStart, e = ta.selectionEnd;
    var ls = v.lastIndexOf("\n", s - 1) + 1;
    var le = v.indexOf("\n", e > s && v[e - 1] === "\n" ? e - 1 : e);
    if (le < 0) le = v.length;
    if (!outdent && s === e) {
      var line = v.slice(ls, le);
      var m = /^(\s*)([-*+]|\d+[.)])\s/.exec(line);
      var unit = m ? new Array(m[2].length + 2).join(" ") : "    ";
      if (m) this.replace(ls, ls, unit, s + unit.length);
      else this.replace(s, e, unit, s + unit.length);
      return;
    }
    var block = v.slice(ls, le).split("\n");
    var delta0 = 0, total = 0;
    var changed = block.map(function (l, i) {
      var r;
      if (outdent) {
        var m2 = /^( {1,4}|\t)/.exec(l);
        r = m2 ? l.slice(m2[0].length) : l;
      } else {
        r = "    " + l;
      }
      var d = r.length - l.length;
      if (i === 0) delta0 = d;
      total += d;
      return r;
    }).join("\n");
    this.replace(ls, le, changed, Math.max(ls, s + delta0), e + total);
  };

  MDEditor.prototype.newline = function (e) {
    var ta = this.ta, v = ta.value;
    var pos = ta.selectionStart;
    if (pos !== ta.selectionEnd) return false;
    var b = this.lineBounds(pos);
    var line = v.slice(b[0], pos);
    var m;
    if ((m = /^(\s*)([-*+]|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?(.*)$/.exec(line))) {
      var rest = v.slice(pos, b[1]);
      if (!m[7].trim() && !rest.trim()) {
        // Empty item: end the list.
        this.replace(b[0], b[1], m[1], b[0] + m[1].length);
        return true;
      }
      var marker = m[3] ? (parseInt(m[3], 10) + 1) + m[4] : m[2];
      var task = m[6] ? "[ ] " : "";
      var insert = "\n" + m[1] + marker + m[5] + task;
      this.replace(pos, pos, insert, pos + insert.length);
      return true;
    }
    if ((m = /^(\s*>\s?)(.*)$/.exec(line))) {
      if (!m[2].trim()) { this.replace(b[0], b[1], "", b[0]); return true; }
      var q = "\n" + m[1];
      this.replace(pos, pos, q, pos + q.length);
      return true;
    }
    if ((m = /^(\s+)\S/.exec(line))) {
      var ind = "\n" + m[1];
      this.replace(pos, pos, ind, pos + ind.length);
      return true;
    }
    return false;
  };

  MDEditor.prototype.keydown = function (e) {
    var mod = e.metaKey || e.ctrlKey;
    if (e.key === "Tab") { e.preventDefault(); this.indent(e.shiftKey); return; }
    if (e.key === "Enter" && !mod && !e.shiftKey && !e.altKey && !e.isComposing) {
      if (this.newline(e)) e.preventDefault();
      return;
    }
    if (!mod || e.altKey) return;
    var k = e.key.toLowerCase();
    if (k === "b") { e.preventDefault(); this.wrap("**", "**", "粗体"); }
    else if (k === "i") { e.preventDefault(); this.wrap("*", "*", "斜体"); }
    else if (k === "k") {
      e.preventDefault();
      var ta = this.ta, s = ta.selectionStart, en = ta.selectionEnd;
      var label = ta.value.slice(s, en) || "链接";
      var text = "[" + label + "](url)";
      this.replace(s, en, text, s + label.length + 3, s + label.length + 6);
    }
  };

  g.MDEditor = MDEditor;
})(window);

// MDReader Explorer thumbnail handler: draws the first page of a .md file as a small "paper"
// (same look as the macOS Quick Look thumbnail). Registered per-user by the installer.

#include <windows.h>
#include <objidl.h>
#include <algorithm>
// GDI+ headers use unqualified min/max, which NOMINMAX removes.
namespace Gdiplus { using std::min; using std::max; }
#include <gdiplus.h>
#include <shlwapi.h>
#include <thumbcache.h>

#include <algorithm>
#include <atomic>
#include <memory>
#include <regex>
#include <string>
#include <vector>

// {12A87F8B-65AB-49E4-A3B5-F60AE714B4E9}
static const CLSID CLSID_MDReaderThumb = {0x12a87f8b, 0x65ab, 0x49e4, {0xa3, 0xb5, 0xf6, 0x0a, 0xe7, 0x14, 0xb4, 0xe9}};

static std::atomic<long> g_dllRefs{0};

namespace {

using namespace Gdiplus;

// ---------------------------------------------------------------- decoding

std::wstring Decode(const std::string& b) {
    const auto* u = reinterpret_cast<const unsigned char*>(b.data());
    auto conv = [&](UINT cp, const char* p, int n, DWORD flags, bool* ok) {
        int len = MultiByteToWideChar(cp, flags, p, n, nullptr, 0);
        if (len <= 0) { *ok = false; return std::wstring(); }
        std::wstring w(len, 0);
        MultiByteToWideChar(cp, flags, p, n, &w[0], len);
        *ok = true;
        return w;
    };
    bool ok = false;
    if (b.size() >= 3 && u[0] == 0xEF && u[1] == 0xBB && u[2] == 0xBF)
        return conv(CP_UTF8, b.data() + 3, static_cast<int>(b.size() - 3), 0, &ok);
    if (b.size() >= 2 && u[0] == 0xFF && u[1] == 0xFE)
        return std::wstring(reinterpret_cast<const wchar_t*>(b.data() + 2), (b.size() - 2) / 2);
    // Drop a multi-byte sequence cut off by the read limit before strict UTF-8 decoding.
    for (int cut = 0; cut <= 3 && cut < static_cast<int>(b.size()); ++cut) {
        std::wstring w = conv(CP_UTF8, b.data(), static_cast<int>(b.size()) - cut, MB_ERR_INVALID_CHARS, &ok);
        if (ok) return w;
    }
    std::wstring w = conv(54936, b.data(), static_cast<int>(b.size()), 0, &ok);
    return ok ? w : conv(CP_UTF8, b.data(), static_cast<int>(b.size()), 0, &ok);
}

// ---------------------------------------------------------------- parsing (first page only)

enum class Kind { Heading, Paragraph, Item, Quote, Code, Table, Rule, Image };

struct Block {
    Kind kind;
    std::wstring text;
    int level = 0;             // heading level / list indent
    std::wstring marker;       // list marker
    int task = -1;             // -1 none, 0 open, 1 done
    std::vector<std::vector<std::wstring>> rows;
};

std::wstring Trim(const std::wstring& s) {
    size_t a = s.find_first_not_of(L" \t\r");
    if (a == std::wstring::npos) return L"";
    size_t b = s.find_last_not_of(L" \t\r");
    return s.substr(a, b - a + 1);
}

bool StartsWith(const std::wstring& s, const wchar_t* p) { return s.rfind(p, 0) == 0; }

std::wstring StripInline(std::wstring s) {
    static const std::wregex wikiAlias(LR"(!?\[\[[^\]|]*\\?\|([^\]]*)\]\])");
    static const std::wregex wiki(LR"(!?\[\[(?:[^\]]*/)?([^\]/]*)\]\])");
    static const std::wregex image(LR"(!\[[^\]]*\]\([^)]*\))");
    static const std::wregex link(LR"(\[([^\]]*)\]\([^)]*\))");
    static const std::wregex tags(LR"(<[^>]+>)");
    static const std::wregex marks(LR"((\*\*|__|~~|==|\*|`))");
    s = std::regex_replace(s, wikiAlias, L"$1");
    s = std::regex_replace(s, wiki, L"$1");
    s = std::regex_replace(s, image, L"");
    s = std::regex_replace(s, link, L"$1");
    s = std::regex_replace(s, tags, L"");
    s = std::regex_replace(s, marks, L"");
    return s;
}

bool IsTableSep(const std::wstring& l) {
    std::wstring t = Trim(l);
    if (t.find(L'-') == std::wstring::npos || t.find(L'|') == std::wstring::npos) return false;
    return std::all_of(t.begin(), t.end(), [](wchar_t c) { return c == L'|' || c == L'-' || c == L':' || c == L' '; });
}

std::vector<std::wstring> SplitRow(std::wstring t) {
    t = Trim(t);
    if (!t.empty() && t.front() == L'|') t.erase(0, 1);
    if (!t.empty() && t.back() == L'|') t.pop_back();
    std::vector<std::wstring> cells;
    std::wstring cur;
    int wiki = 0;
    for (size_t i = 0; i < t.size(); ++i) {
        if (t.compare(i, 2, L"[[") == 0) wiki++;
        if (t.compare(i, 2, L"]]") == 0 && wiki) wiki--;
        if (t[i] == L'|' && !wiki && (i == 0 || t[i - 1] != L'\\')) { cells.push_back(StripInline(Trim(cur))); cur.clear(); }
        else cur += t[i];
    }
    cells.push_back(StripInline(Trim(cur)));
    return cells;
}

std::vector<Block> Parse(const std::wstring& src) {
    std::vector<std::wstring> lines;
    size_t start = 0;
    while (start <= src.size() && lines.size() < 220) {
        size_t nl = src.find(L'\n', start);
        if (nl == std::wstring::npos) { lines.push_back(src.substr(start)); break; }
        lines.push_back(src.substr(start, nl - start));
        start = nl + 1;
    }
    for (auto& l : lines) if (!l.empty() && l.back() == L'\r') l.pop_back();

    size_t i = 0;
    if (!lines.empty() && Trim(lines[0]) == L"---") {
        for (size_t j = 1; j < lines.size(); ++j)
            if (Trim(lines[j]) == L"---" || Trim(lines[j]) == L"...") { i = j + 1; break; }
    }

    std::vector<Block> blocks;
    std::vector<std::wstring> para;
    auto flush = [&]() {
        if (para.empty()) return;
        std::wstring s;
        for (auto& p : para) s += (s.empty() ? L"" : L" ") + p;
        blocks.push_back({Kind::Paragraph, StripInline(s)});
        para.clear();
    };

    static const std::wregex listRe(LR"(^(\s*)([-*+]|\d{1,4}[.)])\s+(.*)$)");
    while (i < lines.size() && blocks.size() < 60) {
        const std::wstring& raw = lines[i];
        std::wstring t = Trim(raw);

        if (StartsWith(t, L"```") || StartsWith(t, L"~~~")) {
            flush();
            std::wstring fence = t.substr(0, 3), code;
            int n = 0;
            for (++i; i < lines.size() && !StartsWith(Trim(lines[i]), fence.c_str()); ++i)
                if (n++ < 18) code += (code.empty() ? L"" : L"\n") + lines[i];
            ++i;
            blocks.push_back({Kind::Code, code});
            continue;
        }
        if (t.empty()) { flush(); ++i; continue; }
        if (!para.empty() && std::all_of(t.begin(), t.end(), [](wchar_t c) { return c == L'='; })) {
            Block b{Kind::Heading, StripInline(para.back())}; b.level = 1; para.pop_back(); flush();
            blocks.push_back(b); ++i; continue;
        }
        if (t[0] == L'#') {
            size_t h = t.find_first_not_of(L'#');
            if (h != std::wstring::npos && h <= 6 && t[h] == L' ') {
                flush();
                std::wstring text = Trim(t.substr(h));
                while (!text.empty() && text.back() == L'#') text.pop_back();
                Block b{Kind::Heading, StripInline(Trim(text))};
                b.level = static_cast<int>(h);
                blocks.push_back(b); ++i; continue;
            }
        }
        {
            std::wstring c;
            for (wchar_t ch : t) if (ch != L' ') c += ch;
            if (c.size() >= 3 && (c[0] == L'-' || c[0] == L'*' || c[0] == L'_') &&
                std::all_of(c.begin(), c.end(), [&](wchar_t ch) { return ch == c[0]; })) {
                flush(); blocks.push_back({Kind::Rule, L""}); ++i; continue;
            }
        }
        if (t[0] == L'>') {
            flush();
            std::wstring q;
            for (; i < lines.size(); ++i) {
                std::wstring l = Trim(lines[i]);
                if (l.empty() || l[0] != L'>') break;
                size_t k = l.find_first_not_of(L"> ");
                std::wstring s = k == std::wstring::npos ? L"" : l.substr(k);
                if (StartsWith(s, L"[!")) { size_t e = s.find(L']'); s = e == std::wstring::npos ? s : Trim(s.substr(e + 1)); }
                if (!s.empty()) q += (q.empty() ? L"" : L" ") + s;
            }
            blocks.push_back({Kind::Quote, StripInline(q)});
            continue;
        }
        if (t[0] == L'|' || (t.find(L'|') != std::wstring::npos && i + 1 < lines.size() && IsTableSep(lines[i + 1]))) {
            flush();
            Block b{Kind::Table, L""};
            for (; i < lines.size(); ++i) {
                std::wstring l = Trim(lines[i]);
                if (l.empty() || l.find(L'|') == std::wstring::npos) break;
                if (!IsTableSep(l) && b.rows.size() < 12) b.rows.push_back(SplitRow(l));
            }
            if (!b.rows.empty()) blocks.push_back(b);
            continue;
        }
        std::wsmatch m;
        if (std::regex_match(raw, m, listRe)) {
            flush();
            Block b{Kind::Item, L""};
            int indent = 0;
            for (wchar_t ch : m[1].str()) indent += ch == L'\t' ? 4 : 1;
            b.level = std::min(indent / 2, 4);
            std::wstring marker = m[2].str(), rest = m[3].str();
            b.marker = (marker == L"-" || marker == L"*" || marker == L"+") ? L"•" : marker.substr(0, marker.size() - 1) + L".";
            if (StartsWith(rest, L"[ ]")) { b.task = 0; rest = Trim(rest.substr(3)); }
            else if (StartsWith(rest, L"[x]") || StartsWith(rest, L"[X]")) { b.task = 1; rest = Trim(rest.substr(3)); }
            b.text = StripInline(rest);
            blocks.push_back(b); ++i; continue;
        }
        if (StartsWith(t, L"![")) { flush(); blocks.push_back({Kind::Image, L""}); ++i; continue; }
        para.push_back(t[0] == L'<' ? std::regex_replace(t, std::wregex(LR"(<[^>]+>)"), L"") : t);
        ++i;
    }
    flush();
    return blocks;
}

// ---------------------------------------------------------------- drawing

const float kPageW = 600.f;
const float kAspect = 0.78f;
const float kMargin = 44.f;
const wchar_t* kSans = L"Microsoft YaHei UI";
const wchar_t* kMono = L"Consolas";

Color C(unsigned rgb, BYTE a = 255) { return Color(a, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff); }

void FillRoundRect(Graphics& g, const Brush& brush, RectF r, float rad) {
    GraphicsPath p;
    float d = rad * 2;
    p.AddArc(r.X, r.Y, d, d, 180, 90);
    p.AddArc(r.X + r.Width - d, r.Y, d, d, 270, 90);
    p.AddArc(r.X + r.Width - d, r.Y + r.Height - d, d, d, 0, 90);
    p.AddArc(r.X, r.Y + r.Height - d, d, d, 90, 90);
    p.CloseFigure();
    g.FillPath(&brush, &p);
}

float DrawTextBlock(Graphics& g, const std::wstring& s, const Font& f, const Brush& b, float x, float y, float w, float maxY) {
    StringFormat fmt(StringFormat::GenericTypographic());
    fmt.SetFormatFlags(fmt.GetFormatFlags() & ~StringFormatFlagsNoWrap);
    fmt.SetTrimming(StringTrimmingEllipsisWord);
    RectF layout(x, y, w, 10000.f), bound;
    g.MeasureString(s.c_str(), -1, &f, layout, &fmt, &bound);
    float h = std::min(bound.Height, std::max(0.f, maxY - y + 40.f));
    g.DrawString(s.c_str(), -1, &f, RectF(x, y, w, h + 2), &fmt, &b);
    return bound.Height;
}

void DrawPage(Graphics& g, const std::vector<Block>& blocks, float pageH) {
    g.Clear(C(0xffffff));
    SolidBrush text(C(0x1f2328)), muted(C(0x636c76)), faint(C(0xe1e4e8)), codeBg(C(0xf5f6f8)),
        accent(C(0x5b5bd6)), link(C(0x0a66d8)), border(C(0xd0d7de));
    Pen hair(C(0xd0d7de), 1.5f), rule(C(0xe1e4e8), 1.5f);

    const float x = kMargin, w = kPageW - kMargin * 2, bottom = pageH - kMargin * 0.9f;
    float y = kMargin * 0.9f;
    const float body = 17.f;
    Kind prev = Kind::Paragraph;
    bool first = true;

    for (const Block& b : blocks) {
        if (y > bottom) break;
        if (!first && prev == Kind::Item && b.kind != Kind::Item) y += 8;
        switch (b.kind) {
        case Kind::Heading: {
            static const float sizes[] = {34, 27, 22, 19, 17, 16};
            if (!first) y += b.level <= 2 ? 16.f : 10.f;
            Font f(kSans, sizes[std::min(b.level, 6) - 1], FontStyleBold, UnitPixel);
            y += DrawTextBlock(g, b.text, f, text, x, y, w, bottom);
            if (b.level <= 2) { y += 6; g.FillRectangle(&faint, x, y, w, 1.5f); y += 3; }
            y += 10;
            break;
        }
        case Kind::Paragraph: {
            Font f(kSans, body, FontStyleRegular, UnitPixel);
            y += DrawTextBlock(g, b.text, f, text, x, y, w, bottom) + 14;
            break;
        }
        case Kind::Item: {
            float indent = b.level * 22.f + 6.f;
            Font f(kSans, body, FontStyleRegular, UnitPixel);
            if (b.task >= 0) {
                RectF box(x + indent + 1, y + 5, 14, 14);
                if (b.task == 1) {
                    FillRoundRect(g, accent, box, 3);
                    Pen tick(C(0xffffff), 2.f);
                    PointF pts[] = {{box.X + 3, box.Y + 7}, {box.X + 6, box.Y + 10.5f}, {box.X + 11, box.Y + 3.5f}};
                    g.DrawLines(&tick, pts, 3);
                } else {
                    Pen p(C(0x636c76), 1.4f);
                    g.DrawRectangle(&p, box);
                }
            } else {
                Font mf(kSans, body, b.marker == L"•" ? FontStyleBold : FontStyleRegular, UnitPixel);
                g.DrawString(b.marker.c_str(), -1, &mf, PointF(x + indent, y), &muted);
            }
            y += DrawTextBlock(g, b.text, f, b.task == 1 ? muted : text, x + indent + 22, y, w - indent - 22, bottom) + 7;
            break;
        }
        case Kind::Quote: {
            Font f(kSans, body, FontStyleRegular, UnitPixel);
            float top = y;
            y += DrawTextBlock(g, b.text, f, muted, x + 20, y, w - 20, bottom);
            g.FillRectangle(&faint, x, top - 2, 4.f, y - top + 4);
            y += 14;
            break;
        }
        case Kind::Code: {
            Font f(kMono, 13.5f, FontStyleRegular, UnitPixel);
            StringFormat fmt(StringFormat::GenericTypographic());
            fmt.SetFormatFlags(StringFormatFlagsNoWrap);
            RectF bound;
            g.MeasureString(b.text.empty() ? L" " : b.text.c_str(), -1, &f, PointF(0, 0), &fmt, &bound);
            float h = std::min(bound.Height + 28.f, bottom - y + 20);
            FillRoundRect(g, codeBg, RectF(x, y, w, h), 8);
            g.SetClip(RectF(x + 14, y + 4, w - 28, h - 8));
            SolidBrush codeText(C(0x333b47));
            g.DrawString(b.text.c_str(), -1, &f, PointF(x + 14, y + 14), &fmt, &codeText);
            g.ResetClip();
            y += h + 16;
            break;
        }
        case Kind::Table: {
            size_t cols = 1;
            for (auto& r : b.rows) cols = std::max(cols, r.size());
            float colW = w / cols, rowH = 30, top = y;
            StringFormat fmt(StringFormat::GenericTypographic());
            fmt.SetFormatFlags(StringFormatFlagsNoWrap);
            fmt.SetTrimming(StringTrimmingEllipsisCharacter);
            for (size_t r = 0; r < b.rows.size() && y < bottom; ++r) {
                if (r == 0) g.FillRectangle(&codeBg, x, y, w, rowH);
                Font f(kSans, 14.5f, r == 0 ? FontStyleBold : FontStyleRegular, UnitPixel);
                for (size_t c = 0; c < cols; ++c) {
                    std::wstring cell = c < b.rows[r].size() ? b.rows[r][c] : L"";
                    g.DrawString(cell.c_str(), -1, &f, RectF(x + c * colW + 9, y + 6, colW - 18, rowH - 8), &fmt, &text);
                }
                y += rowH;
                g.FillRectangle(&faint, x, y - 1, w, 1.f);
            }
            g.DrawRectangle(&hair, x, top, w, y - top);
            for (size_t c = 1; c < cols; ++c) g.DrawLine(&rule, x + c * colW, top, x + c * colW, y);
            y += 16;
            break;
        }
        case Kind::Rule:
            y += 8;
            g.FillRectangle(&faint, x, y, w, 2.f);
            y += 18;
            break;
        case Kind::Image:
            FillRoundRect(g, codeBg, RectF(x, y, w, 130), 8);
            y += 146;
            break;
        }
        prev = b.kind;
        first = false;
    }
    if (blocks.empty()) {
        Font f(kSans, body, FontStyleRegular, UnitPixel);
        g.DrawString(L"Empty document", -1, &f, PointF(x, y), &muted);
    }
    g.ResetTransform();
}

// ---------------------------------------------------------------- COM objects

class ThumbProvider : public IThumbnailProvider, public IInitializeWithStream {
public:
    ThumbProvider() { ++g_dllRefs; }
    virtual ~ThumbProvider() { if (stream_) stream_->Release(); --g_dllRefs; }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        static const QITAB qit[] = {
            QITABENT(ThumbProvider, IInitializeWithStream),
            QITABENT(ThumbProvider, IThumbnailProvider),
            {nullptr, 0},
        };
        return QISearch(this, qit, riid, ppv);
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
    IFACEMETHODIMP_(ULONG) Release() override {
        long r = --refs_;
        if (!r) delete this;
        return r;
    }

    IFACEMETHODIMP Initialize(IStream* stream, DWORD) override {
        if (stream_) return HRESULT_FROM_WIN32(ERROR_ALREADY_INITIALIZED);
        stream_ = stream;
        stream_->AddRef();
        return S_OK;
    }

    IFACEMETHODIMP GetThumbnail(UINT cx, HBITMAP* phbmp, WTS_ALPHATYPE* alpha) override {
        if (!stream_ || !phbmp) return E_UNEXPECTED;
        std::string bytes(48 * 1024, 0);
        ULONG read = 0;
        stream_->Read(&bytes[0], static_cast<ULONG>(bytes.size()), &read);
        bytes.resize(read);
        std::vector<Block> blocks = Parse(Decode(bytes));

        GdiplusStartupInput in;
        ULONG_PTR token = 0;
        if (GdiplusStartup(&token, &in, nullptr) != Ok) return E_FAIL;
        HRESULT hr = E_FAIL;
        {
            UINT h = std::max<UINT>(cx, 16);
            UINT w = std::max<UINT>(static_cast<UINT>(h * kAspect), 12);
            Bitmap bmp(w, h, PixelFormat32bppARGB);
            Graphics g(&bmp);
            g.SetSmoothingMode(SmoothingModeAntiAlias);
            g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
            g.SetPixelOffsetMode(PixelOffsetModeHighQuality);
            float scale = w / kPageW;
            g.ScaleTransform(scale, scale);
            DrawPage(g, blocks, h / scale);
            Pen frame(C(0xd0d7de), 1.f);
            g.DrawRectangle(&frame, 0.f, 0.f, static_cast<REAL>(w - 1), static_cast<REAL>(h - 1));
            if (bmp.GetHBITMAP(Color(0, 0, 0, 0), phbmp) == Ok) {
                *alpha = WTSAT_ARGB;
                hr = S_OK;
            }
        }
        GdiplusShutdown(token);
        return hr;
    }

private:
    std::atomic<long> refs_{1};
    IStream* stream_ = nullptr;
};

class Factory : public IClassFactory {
public:
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        static const QITAB qit[] = {QITABENT(Factory, IClassFactory), {nullptr, 0}};
        return QISearch(this, qit, riid, ppv);
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return 2; }
    IFACEMETHODIMP_(ULONG) Release() override { return 1; }
    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override {
        if (outer) return CLASS_E_NOAGGREGATION;
        auto* p = new (std::nothrow) ThumbProvider();
        if (!p) return E_OUTOFMEMORY;
        HRESULT hr = p->QueryInterface(riid, ppv);
        p->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL lock) override {
        if (lock) ++g_dllRefs; else --g_dllRefs;
        return S_OK;
    }
};

Factory g_factory;

}  // namespace

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** ppv) {
    if (!IsEqualCLSID(clsid, CLSID_MDReaderThumb)) return CLASS_E_CLASSNOTAVAILABLE;
    return g_factory.QueryInterface(riid, ppv);
}

STDAPI DllCanUnloadNow() { return g_dllRefs == 0 ? S_OK : S_FALSE; }

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(module);
    return TRUE;
}

// MDReader for Windows — a Win32 shell around WebView2 that hosts the shared web renderer
// (shared/web). One document per window; the page provides the toolbar, editor and sidebar.

#include <windows.h>
#include <commdlg.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <wrl.h>

#include <algorithm>
#include <string>
#include <vector>

#include "WebView2.h"
#include "Json.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

const wchar_t* kWindowClass = L"MDReaderWindow";
const wchar_t* kAppHost = L"mdreader.local";
const wchar_t* kDocHost = L"doc.mdreader.local";
const wchar_t* kRegKey = L"Software\\MDReader";
const UINT_PTR kWatchTimer = 1;
const UINT_PTR kSaveTimer = 2;

// ---------------------------------------------------------------- helpers

std::wstring ExeDir() {
    wchar_t buf[MAX_PATH];
    GetModuleFileNameW(nullptr, buf, MAX_PATH);
    PathRemoveFileSpecW(buf);
    return buf;
}

std::wstring FileName(const std::wstring& path) { return PathFindFileNameW(path.c_str()); }

std::wstring DirName(const std::wstring& path) {
    std::wstring d = path;
    size_t i = d.find_last_of(L"\\/");
    return i == std::wstring::npos ? L"" : d.substr(0, i);
}

std::wstring Lower(std::wstring s) {
    std::transform(s.begin(), s.end(), s.begin(), [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
    return s;
}

std::wstring Ext(const std::wstring& path) {
    const wchar_t* e = PathFindExtensionW(path.c_str());
    return Lower(*e ? std::wstring(e + 1) : L"");
}

bool IsMarkdown(const std::wstring& path) {
    static const wchar_t* exts[] = {L"md", L"markdown", L"mdown", L"mkd", L"mkdn", L"mdx", L"txt"};
    std::wstring e = Ext(path);
    for (auto x : exts) if (e == x) return true;
    return false;
}

bool FileExists(const std::wstring& p) {
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

bool DirExists(const std::wstring& p) {
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}

FILETIME WriteTime(const std::wstring& p) {
    WIN32_FILE_ATTRIBUTE_DATA d{};
    GetFileAttributesExW(p.c_str(), GetFileExInfoStandard, &d);
    return d.ftLastWriteTime;
}

double WriteTimeMs(const std::wstring& p) {
    FILETIME ft = WriteTime(p);
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    if (!u.QuadPart) return 0;
    return static_cast<double>((u.QuadPart - 116444736000000000ULL) / 10000ULL);
}

/// Percent-encodes characters that would break a URL path; non-ASCII is left to the URL parser.
std::wstring UrlPath(const std::wstring& path) {
    std::wstring out;
    for (wchar_t c : path) {
        if (c == L'\\') out += L'/';
        else if (c == L' ') out += L"%20";
        else if (c == L'#') out += L"%23";
        else if (c == L'?') out += L"%3F";
        else if (c == L'%') out += L"%25";
        else out += c;
    }
    return out;
}

std::wstring UnescapeUrl(std::wstring s) {
    std::vector<wchar_t> buf(s.begin(), s.end());
    buf.push_back(0);
    DWORD n = static_cast<DWORD>(buf.size());
    UrlUnescapeW(buf.data(), nullptr, &n, URL_UNESCAPE_INPLACE | URL_UNESCAPE_AS_UTF8);
    return buf.data();
}

// ---------------------------------------------------------------- registry settings

std::wstring RegGet(const wchar_t* name, const std::wstring& def) {
    wchar_t buf[2048];
    DWORD size = sizeof(buf);
    if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, name, RRF_RT_REG_SZ, nullptr, buf, &size) == ERROR_SUCCESS) return buf;
    return def;
}

void RegSet(const wchar_t* name, const std::wstring& value) {
    RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, name, REG_SZ, value.c_str(),
                    static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

std::vector<std::wstring> RecentFiles() {
    std::vector<std::wstring> out;
    wchar_t buf[32768];
    DWORD size = sizeof(buf);
    if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"Recent", RRF_RT_REG_MULTI_SZ, nullptr, buf, &size) == ERROR_SUCCESS) {
        for (const wchar_t* p = buf; *p; p += wcslen(p) + 1) out.push_back(p);
    }
    return out;
}

void SaveRecentFiles(const std::vector<std::wstring>& list) {
    std::wstring blob;
    for (auto& s : list) { blob += s; blob.push_back(0); }
    blob.push_back(0);
    RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"Recent", REG_MULTI_SZ, blob.data(),
                    static_cast<DWORD>(blob.size() * sizeof(wchar_t)));
}

void NoteRecent(const std::wstring& path) {
    auto list = RecentFiles();
    list.erase(std::remove_if(list.begin(), list.end(),
                              [&](const std::wstring& s) { return lstrcmpiW(s.c_str(), path.c_str()) == 0; }),
               list.end());
    list.insert(list.begin(), path);
    if (list.size() > 20) list.resize(20);
    SaveRecentFiles(list);
    SHAddToRecentDocs(SHARD_PATHW, path.c_str());
}

std::wstring UiLang() { return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE ? L"zh" : L"en"; }

std::wstring SettingsJson() {
    return L"{\"style\":" + JsonStr(RegGet(L"style", L"github")) +
           L",\"theme\":" + JsonStr(RegGet(L"theme", L"auto")) +
           L",\"zoom\":" + RegGet(L"zoom", L"1") +
           L",\"toc\":" + (RegGet(L"toc", L"1") == L"1" ? L"true" : L"false") +
           L",\"sidebarTab\":" + JsonStr(RegGet(L"sidebarTab", L"outline")) +
           L",\"lang\":" + JsonStr(UiLang()) + L"}";
}

COLORREF ParseColor(const std::wstring& hex, COLORREF def) {
    if (hex.size() == 7 && hex[0] == L'#') {
        unsigned v = wcstoul(hex.c_str() + 1, nullptr, 16);
        return RGB((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
    }
    return def;
}

// ---------------------------------------------------------------- text encoding

enum class Enc { Utf8, Utf8Bom, Utf16LE, Utf16BE, Gb18030 };

bool ReadBytes(const std::wstring& path, std::string& out) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    GetFileSizeEx(h, &size);
    out.resize(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    BOOL ok = out.empty() || ReadFile(h, &out[0], static_cast<DWORD>(out.size()), &read, nullptr);
    CloseHandle(h);
    out.resize(read);
    return ok != FALSE;
}

std::wstring FromCodePage(const char* p, int n, UINT cp, DWORD flags, bool* ok) {
    int len = MultiByteToWideChar(cp, flags, p, n, nullptr, 0);
    if (len <= 0 && n > 0) { if (ok) *ok = false; return L""; }
    std::wstring w(len, 0);
    if (len) MultiByteToWideChar(cp, flags, p, n, &w[0], len);
    if (ok) *ok = true;
    return w;
}

std::wstring Decode(const std::string& b, Enc& enc) {
    const auto* u = reinterpret_cast<const unsigned char*>(b.data());
    if (b.size() >= 3 && u[0] == 0xEF && u[1] == 0xBB && u[2] == 0xBF) {
        enc = Enc::Utf8Bom;
        return FromCodePage(b.data() + 3, static_cast<int>(b.size() - 3), CP_UTF8, 0, nullptr);
    }
    if (b.size() >= 2 && u[0] == 0xFF && u[1] == 0xFE) {
        enc = Enc::Utf16LE;
        return std::wstring(reinterpret_cast<const wchar_t*>(b.data() + 2), (b.size() - 2) / 2);
    }
    if (b.size() >= 2 && u[0] == 0xFE && u[1] == 0xFF) {
        enc = Enc::Utf16BE;
        std::wstring w((b.size() - 2) / 2, 0);
        for (size_t i = 0; i < w.size(); ++i) w[i] = static_cast<wchar_t>((u[2 + i * 2] << 8) | u[3 + i * 2]);
        return w;
    }
    bool ok = false;
    std::wstring w = FromCodePage(b.data(), static_cast<int>(b.size()), CP_UTF8, MB_ERR_INVALID_CHARS, &ok);
    if (ok) { enc = Enc::Utf8; return w; }
    w = FromCodePage(b.data(), static_cast<int>(b.size()), 54936, MB_ERR_INVALID_CHARS, &ok);
    if (ok) { enc = Enc::Gb18030; return w; }
    enc = Enc::Utf8;
    return FromCodePage(b.data(), static_cast<int>(b.size()), CP_UTF8, 0, nullptr);
}

std::string ToCodePage(const std::wstring& w, UINT cp) {
    int len = WideCharToMultiByte(cp, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(len, 0);
    if (len) WideCharToMultiByte(cp, 0, w.data(), static_cast<int>(w.size()), &s[0], len, nullptr, nullptr);
    return s;
}

std::string Encode(const std::wstring& w, Enc enc) {
    switch (enc) {
    case Enc::Utf8Bom: return "\xEF\xBB\xBF" + ToCodePage(w, CP_UTF8);
    case Enc::Utf16LE: {
        std::string s = "\xFF\xFE";
        s.append(reinterpret_cast<const char*>(w.data()), w.size() * 2);
        return s;
    }
    case Enc::Utf16BE: {
        std::string s = "\xFE\xFF";
        for (wchar_t c : w) { s.push_back(static_cast<char>(c >> 8)); s.push_back(static_cast<char>(c & 0xff)); }
        return s;
    }
    case Enc::Gb18030: return ToCodePage(w, 54936);
    default: return ToCodePage(w, CP_UTF8);
    }
}

bool WriteAtomically(const std::wstring& path, const std::string& bytes) {
    std::wstring tmp = path + L".mdreader-tmp";
    HANDLE h = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    BOOL ok = bytes.empty() || WriteFile(h, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr);
    CloseHandle(h);
    if (!ok) { DeleteFileW(tmp.c_str()); return false; }
    if (!ReplaceFileW(path.c_str(), tmp.c_str(), nullptr, REPLACEFILE_IGNORE_MERGE_ERRORS, nullptr, nullptr)) {
        if (!MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) { DeleteFileW(tmp.c_str()); return false; }
    }
    return true;
}

// ---------------------------------------------------------------- window state

HWND g_hwnd = nullptr;
ComPtr<ICoreWebView2Environment> g_env;
ComPtr<ICoreWebView2Controller> g_ctrl;
ComPtr<ICoreWebView2> g_web;
std::wstring g_path;          // current document ("" = start page)
std::wstring g_text;
Enc g_enc = Enc::Utf8;
bool g_crlf = false;
bool g_dirty = false;
bool g_ready = false;
bool g_editOnOpen = false;
FILETIME g_mtime{};
std::wstring g_docRoot;

void Exec(const std::wstring& script) {
    if (g_web) g_web->ExecuteScript(script.c_str(), nullptr);
}

void UpdateTitle() {
    std::wstring name = g_path.empty() ? L"MDReader" : FileName(g_path);
    SetWindowTextW(g_hwnd, (g_path.empty() ? name : name + (g_dirty ? L" •" : L"") + L" - MDReader").c_str());
    if (!g_path.empty()) Exec(L"window.MDShell && MDShell.setTitle(" + JsonStr(name) + L"," + JsonBool(g_dirty) + L")");
}

std::wstring BaseUrl() {
    // The document's drive is mapped to https://doc.mdreader.local/ so ../relative images work.
    std::wstring rel = g_path.substr(g_docRoot.size());
    return L"https://" + std::wstring(kDocHost) + L"/" + UrlPath(rel);
}

void MapDocumentHost() {
    ComPtr<ICoreWebView2_3> w3;
    if (!g_web || FAILED(g_web.As(&w3)) || g_path.empty()) return;
    wchar_t root[MAX_PATH];
    wcscpy_s(root, g_path.c_str());
    PathStripToRootW(root);
    g_docRoot = root;
    if (!g_docRoot.empty() && g_docRoot.back() != L'\\') g_docRoot += L'\\';
    w3->ClearVirtualHostNameToFolderMapping(kDocHost);
    w3->SetVirtualHostNameToFolderMapping(kDocHost, g_docRoot.c_str(), COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW);
}

void Render(bool keepScroll) {
    if (!g_ready || g_path.empty()) return;
    Exec(L"MDReader.render(" + JsonStr(g_text) + L"," + JsonStr(BaseUrl()) + L"," + JsonBool(keepScroll) + L")");
    UpdateTitle();
    if (g_editOnOpen) { g_editOnOpen = false; Exec(L"MDReader.setMode(true)"); }
}

bool LoadFile(const std::wstring& path) {
    std::string bytes;
    if (!ReadBytes(path, bytes)) return false;
    g_text = Decode(bytes, g_enc);
    g_crlf = g_text.find(L"\r\n") != std::wstring::npos;
    g_mtime = WriteTime(path);
    return true;
}

bool SaveNow() {
    if (!g_dirty || g_path.empty()) return true;
    std::wstring text = g_text;
    if (g_crlf) {
        std::wstring t;
        t.reserve(text.size() + text.size() / 20);
        for (size_t i = 0; i < text.size(); ++i) {
            if (text[i] == L'\n' && (i == 0 || text[i - 1] != L'\r')) t += L'\r';
            t += text[i];
        }
        text.swap(t);
    }
    if (!WriteAtomically(g_path, Encode(text, g_enc))) {
        MessageBoxW(g_hwnd, (L"无法保存文件 / Could not save:\n" + g_path).c_str(), L"MDReader", MB_ICONERROR);
        return false;
    }
    g_mtime = WriteTime(g_path);
    g_dirty = false;
    KillTimer(g_hwnd, kSaveTimer);
    UpdateTitle();
    return true;
}

void ShowStartPage() {
    g_path.clear();
    g_ready = false;
    if (g_web) g_web->Navigate((L"https://" + std::wstring(kAppHost) + L"/start.html").c_str());
    UpdateTitle();
}

/// Opens a document in this window (saving the current one first).
bool OpenHere(const std::wstring& path, bool editMode = false) {
    if (!SaveNow()) return false;
    if (!LoadFile(path)) {
        MessageBoxW(g_hwnd, (L"无法打开文件 / Could not open:\n" + path).c_str(), L"MDReader", MB_ICONERROR);
        return false;
    }
    bool wasDoc = !g_path.empty() && g_ready;
    g_path = path;
    g_dirty = false;
    g_editOnOpen = editMode;
    NoteRecent(path);
    MapDocumentHost();
    if (wasDoc) {
        Render(false);
    } else {
        g_ready = false;
        g_web->Navigate((L"https://" + std::wstring(kAppHost) + L"/index.html").c_str());
    }
    UpdateTitle();
    return true;
}

void OpenInNewWindow(const std::wstring& path) {
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring args = L"\"" + path + L"\"";
    ShellExecuteW(nullptr, L"open", exe, args.c_str(), nullptr, SW_SHOWNORMAL);
}

/// Opens a markdown file: here when this window is empty or the user asked for it, else a new window.
void OpenDocument(const std::wstring& path, bool sameWindow) {
    if (lstrcmpiW(path.c_str(), g_path.c_str()) == 0) return;
    if (g_path.empty() || sameWindow) OpenHere(path);
    else OpenInNewWindow(path);
}

std::wstring PickFile(bool save, const std::wstring& suggested = L"") {
    wchar_t buf[MAX_PATH] = L"";
    if (!suggested.empty()) wcscpy_s(buf, suggested.c_str());
    OPENFILENAMEW ofn{};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = g_hwnd;
    ofn.lpstrFilter = L"Markdown (*.md;*.markdown;*.txt)\0*.md;*.markdown;*.mdown;*.mkd;*.txt\0All files\0*.*\0";
    ofn.lpstrFile = buf;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrDefExt = L"md";
    ofn.Flags = save ? (OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST) : (OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST);
    BOOL ok = save ? GetSaveFileNameW(&ofn) : GetOpenFileNameW(&ofn);
    return ok ? std::wstring(buf) : L"";
}

void CommandOpen() {
    std::wstring p = PickFile(false);
    if (!p.empty()) OpenDocument(p, false);
}

void CommandNew() {
    std::wstring p = PickFile(true, UiLang() == L"zh" ? L"未命名.md" : L"Untitled.md");
    if (p.empty()) return;
    std::wstring title = FileName(p);
    PathRemoveExtensionW(&title[0]);
    title = title.c_str();
    WriteAtomically(p, ToCodePage(L"# " + title + L"\n\n", CP_UTF8));
    if (g_path.empty()) OpenHere(p, true);
    else OpenInNewWindow(p);
}

void CommandExportPdf() {
    ComPtr<ICoreWebView2_7> w7;
    if (!g_web || FAILED(g_web.As(&w7)) || g_path.empty()) return;
    std::wstring name = FileName(g_path);
    PathRemoveExtensionW(&name[0]);
    name = std::wstring(name.c_str()) + L".pdf";
    wchar_t buf[MAX_PATH];
    wcscpy_s(buf, name.c_str());
    OPENFILENAMEW ofn{};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = g_hwnd;
    ofn.lpstrFilter = L"PDF\0*.pdf\0";
    ofn.lpstrFile = buf;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrDefExt = L"pdf";
    ofn.Flags = OFN_OVERWRITEPROMPT;
    if (!GetSaveFileNameW(&ofn)) return;
    w7->PrintToPdf(buf, nullptr, Callback<ICoreWebView2PrintToPdfCompletedHandler>(
        [](HRESULT, BOOL ok) -> HRESULT {
            if (!ok) MessageBoxW(g_hwnd, L"导出 PDF 失败 / PDF export failed", L"MDReader", MB_ICONERROR);
            return S_OK;
        }).Get());
}

// ---------------------------------------------------------------- sidebar: files & wikilinks

std::wstring Crumbs(const std::wstring& dir) {
    wchar_t home[MAX_PATH] = L"";
    SHGetFolderPathW(nullptr, CSIDL_PROFILE, nullptr, 0, home);
    std::vector<std::pair<std::wstring, std::wstring>> chain;
    std::wstring cur = dir;
    while (!cur.empty()) {
        bool isHome = lstrcmpiW(cur.c_str(), home) == 0;
        std::wstring name = isHome ? L"~" : FileName(cur);
        if (name.empty() || PathIsRootW(cur.c_str())) name = cur;
        chain.insert(chain.begin(), {name, cur});
        if (isHome || PathIsRootW(cur.c_str())) break;
        std::wstring parent = DirName(cur);
        if (parent == cur || parent.empty()) break;
        if (parent.size() == 2 && parent[1] == L':') parent += L'\\';
        cur = parent;
    }
    if (chain.size() > 5) {
        auto hidden = chain[chain.size() - 4];
        std::vector<std::pair<std::wstring, std::wstring>> c2 = {chain[0], {L"…", hidden.second}};
        c2.insert(c2.end(), chain.end() - 3, chain.end());
        chain = c2;
    }
    std::wstring out = L"[";
    for (size_t i = 0; i < chain.size(); ++i) {
        if (i) out += L",";
        out += L"{\"name\":" + JsonStr(chain[i].first) + L",\"path\":" + JsonStr(chain[i].second) + L"}";
    }
    return out + L"]";
}

void ListDirectory(std::wstring dir) {
    if (dir.empty()) dir = g_path.empty() ? L"" : DirName(g_path);
    if (dir.empty()) return;
    if (dir.size() == 2 && dir[1] == L':') dir += L'\\';
    std::vector<std::wstring> dirs, files;
    WIN32_FIND_DATAW fd;
    std::wstring pattern = dir + (dir.back() == L'\\' ? L"*" : L"\\*");
    HANDLE h = FindFirstFileW(pattern.c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            std::wstring n = fd.cFileName;
            if (n == L"." || n == L".." || n[0] == L'.' || (fd.dwFileAttributes & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM))) continue;
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) dirs.push_back(n);
            else if (IsMarkdown(n)) files.push_back(n);
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    auto cmp = [](const std::wstring& a, const std::wstring& b) { return StrCmpLogicalW(a.c_str(), b.c_str()) < 0; };
    std::sort(dirs.begin(), dirs.end(), cmp);
    std::sort(files.begin(), files.end(), cmp);
    std::wstring base = dir.back() == L'\\' ? dir : dir + L"\\";
    std::wstring entries = L"[";
    bool first = true;
    auto add = [&](const std::wstring& n, bool isDir) {
        std::wstring full = base + n;
        if (!first) entries += L",";
        first = false;
        entries += L"{\"name\":" + JsonStr(n) + L",\"path\":" + JsonStr(full) + L",\"dir\":" + JsonBool(isDir) +
                   L",\"current\":" + JsonBool(!isDir && lstrcmpiW(full.c_str(), g_path.c_str()) == 0) + L"}";
    };
    for (auto& d : dirs) add(d, true);
    for (auto& f : files) add(f, false);
    entries += L"]";
    Exec(L"MDReader.setFiles({\"path\":" + JsonStr(dir) + L",\"crumbs\":" + Crumbs(dir) + L",\"entries\":" + entries + L"})");
}

bool FindByName(const std::wstring& dir, const std::wstring& name, std::wstring& found, int& budget, int depth) {
    if (depth > 12 || budget <= 0) return false;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return false;
    std::vector<std::wstring> subdirs;
    do {
        std::wstring n = fd.cFileName;
        if (n == L"." || n == L".." || n[0] == L'.') continue;
        if (--budget <= 0) break;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) subdirs.push_back(dir + L"\\" + n);
        else if (lstrcmpiW(n.c_str(), name.c_str()) == 0) { found = dir + L"\\" + n; FindClose(h); return true; }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    for (auto& s : subdirs) if (FindByName(s, name, found, budget, depth + 1)) return true;
    return false;
}

std::wstring ResolveWikilink(std::wstring target) {
    std::replace(target.begin(), target.end(), L'/', L'\\');
    std::vector<std::wstring> names = {target};
    if (Ext(target).empty()) names.insert(names.begin(), target + L".md");
    std::wstring dir = DirName(g_path);
    for (auto& n : names) if (FileExists(dir + L"\\" + n)) return dir + L"\\" + n;
    std::wstring root = dir, cur = dir;
    for (int i = 0; i < 12; ++i) {
        if (DirExists(cur + L"\\.obsidian")) { root = cur; break; }
        std::wstring parent = DirName(cur);
        if (parent.empty() || parent == cur) break;
        cur = parent;
    }
    for (auto& n : names) if (FileExists(root + L"\\" + n)) return root + L"\\" + n;
    std::wstring found;
    int budget = 30000;
    if (FindByName(root, FileName(names[0]), found, budget, 0)) return found;
    return L"";
}

// ---------------------------------------------------------------- page messages

void ApplyChrome(const std::wstring& bgHex, bool dark) {
    RegSet(L"lastBG", bgHex);
    BOOL d = dark ? TRUE : FALSE;
    DwmSetWindowAttribute(g_hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &d, sizeof(d));
    COLORREF c = ParseColor(bgHex, RGB(255, 255, 255));
    DwmSetWindowAttribute(g_hwnd, 35 /* DWMWA_CAPTION_COLOR (Win11) */, &c, sizeof(c));
    ComPtr<ICoreWebView2Controller2> c2;
    if (g_ctrl && SUCCEEDED(g_ctrl.As(&c2))) {
        COREWEBVIEW2_COLOR col{255, GetRValue(c), GetGValue(c), GetBValue(c)};
        c2->put_DefaultBackgroundColor(col);
    }
}

void SendRecents() {
    wchar_t home[MAX_PATH] = L"";
    SHGetFolderPathW(nullptr, CSIDL_PROFILE, nullptr, 0, home);
    std::wstring homeS = home;
    std::wstring arr = L"[";
    bool first = true;
    for (auto& p : RecentFiles()) {
        if (!FileExists(p)) continue;
        std::wstring dir = DirName(p);
        if (!homeS.empty() && dir.size() >= homeS.size() && lstrcmpiW(dir.substr(0, homeS.size()).c_str(), homeS.c_str()) == 0)
            dir = L"~" + dir.substr(homeS.size());
        if (!first) arr += L",";
        first = false;
        wchar_t ms[32];
        swprintf(ms, 32, L"%.0f", WriteTimeMs(p));
        arr += L"{\"name\":" + JsonStr(FileName(p)) + L",\"dir\":" + JsonStr(dir) + L",\"path\":" + JsonStr(p) +
               L",\"modified\":" + ms + L"}";
    }
    Exec(L"MDStart.setRecents(" + arr + L"])");
}

void OnMessage(const JVal& m) {
    std::wstring type = m[L"type"].str();
    if (type == L"ready") {
        g_ready = true;
        if (g_path.empty()) {
            Exec(L"MDStart.configure(" + SettingsJson() + L"); MDStart.setVersion(\"1.0.0\")");
            SendRecents();
        } else {
            Exec(L"MDReader.configure(" + SettingsJson() + L", false)");
            Render(false);
        }
    } else if (type == L"edited") {
        std::wstring text = m[L"text"].str();
        if (text != g_text) {
            g_text = text;
            g_dirty = true;
            UpdateTitle();
            SetTimer(g_hwnd, kSaveTimer, 1200, nullptr);   // autosave shortly after typing stops
        }
    } else if (type == L"chrome") {
        ApplyChrome(m[L"bg"].str(L"#ffffff"), m[L"dark"].boolean());
    } else if (type == L"listDir") {
        ListDirectory(m[L"path"].str());
    } else if (type == L"openFile") {
        std::wstring p = m[L"path"].str();
        if (m[L"newWindow"].boolean()) OpenInNewWindow(p); else OpenHere(p);
    } else if (type == L"pinTOC") {
        RegSet(L"toc", m[L"value"].boolean(true) ? L"1" : L"0");
    } else if (type == L"sidebarTab") {
        RegSet(L"sidebarTab", m[L"tab"].str(L"outline"));
    } else if (type == L"setting") {
        std::wstring key = m[L"key"].str();
        const JVal& v = m[L"value"];
        if (key == L"style" || key == L"theme") RegSet(key.c_str(), v.str());
        else if (key == L"zoom") { wchar_t b[32]; swprintf(b, 32, L"%.2f", v.num(1)); RegSet(L"zoom", b); }
    } else if (type == L"wikilink") {
        std::wstring found = ResolveWikilink(m[L"path"].str());
        if (found.empty()) {
            MessageBeep(MB_ICONWARNING);
            Exec(L"MDReader.toast(" + JsonStr((UiLang() == L"zh" ? L"未找到：" : L"Not found: ") + m[L"path"].str()) + L")");
        } else if (IsMarkdown(found)) {
            OpenHere(found);
        } else {
            ShellExecuteW(nullptr, L"open", found.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        }
    } else if (type == L"command") {
        std::wstring name = m[L"name"].str();
        if (name == L"open") CommandOpen();
        else if (name == L"new") CommandNew();
        else if (name == L"save") SaveNow();
        else if (name == L"print") Exec(L"window.print()");
        else if (name == L"exportPdf") CommandExportPdf();
    } else if (type == L"open") {            // start page
        CommandOpen();
    } else if (type == L"new") {
        CommandNew();
    } else if (type == L"openRecent") {
        OpenHere(m[L"path"].str());
    } else if (type == L"clearRecents") {
        SaveRecentFiles({});
        SendRecents();
    }
}

/// Navigations away from our page: open markdown files, hand everything else to the system.
bool HandleNavigation(const std::wstring& uri) {
    std::wstring appPrefix = L"https://" + std::wstring(kAppHost) + L"/";
    if (uri.rfind(appPrefix, 0) == 0) return false;   // allow
    std::wstring docPrefix = L"https://" + std::wstring(kDocHost) + L"/";
    std::wstring path;
    if (uri.rfind(docPrefix, 0) == 0) {
        std::wstring rest = uri.substr(docPrefix.size());
        size_t cut = rest.find_first_of(L"?#");
        if (cut != std::wstring::npos) rest = rest.substr(0, cut);
        path = g_docRoot + UnescapeUrl(rest);
        std::replace(path.begin(), path.end(), L'/', L'\\');
    } else if (uri.rfind(L"file:", 0) == 0) {
        wchar_t buf[MAX_PATH * 2];
        DWORD n = MAX_PATH * 2;
        if (SUCCEEDED(PathCreateFromUrlW(uri.c_str(), buf, &n, 0))) path = buf;
    }
    if (!path.empty()) {
        if (IsMarkdown(path) && FileExists(path)) OpenDocument(path, true);
        else ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    } else if (uri.rfind(L"http", 0) == 0 || uri.rfind(L"mailto:", 0) == 0) {
        ShellExecuteW(nullptr, L"open", uri.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    }
    return true;   // cancel
}

// ---------------------------------------------------------------- WebView2 setup

void InitWebView() {
    wchar_t local[MAX_PATH] = L"";
    SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, local);
    std::wstring userData = std::wstring(local) + L"\\MDReader\\WebView2";

    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(nullptr, userData.c_str(), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                if (FAILED(result) || !env) {
                    if (MessageBoxW(g_hwnd,
                                    L"MDReader 需要 Microsoft Edge WebView2 运行时。现在下载吗？\n"
                                    L"MDReader needs the Microsoft Edge WebView2 Runtime. Download it now?",
                                    L"MDReader", MB_YESNO | MB_ICONINFORMATION) == IDYES) {
                        ShellExecuteW(nullptr, L"open", L"https://go.microsoft.com/fwlink/p/?LinkId=2124703",
                                      nullptr, nullptr, SW_SHOWNORMAL);
                    }
                    PostMessageW(g_hwnd, WM_CLOSE, 0, 0);
                    return S_OK;
                }
                g_env = env;
                return env->CreateCoreWebView2Controller(g_hwnd,
                    Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [](HRESULT res, ICoreWebView2Controller* controller) -> HRESULT {
                            if (FAILED(res) || !controller) return S_OK;
                            g_ctrl = controller;
                            g_ctrl->get_CoreWebView2(&g_web);

                            COLORREF bg = ParseColor(RegGet(L"lastBG", L"#ffffff"), RGB(255, 255, 255));
                            ComPtr<ICoreWebView2Controller2> c2;
                            if (SUCCEEDED(g_ctrl.As(&c2))) {
                                COREWEBVIEW2_COLOR col{255, GetRValue(bg), GetGValue(bg), GetBValue(bg)};
                                c2->put_DefaultBackgroundColor(col);
                            }

                            ComPtr<ICoreWebView2Settings> s;
                            g_web->get_Settings(&s);
                            s->put_IsStatusBarEnabled(FALSE);
                            s->put_IsZoomControlEnabled(FALSE);
                            s->put_AreDefaultContextMenusEnabled(TRUE);
#ifdef NDEBUG
                            s->put_AreDevToolsEnabled(FALSE);
#endif
                            ComPtr<ICoreWebView2Settings3> s3;
                            if (SUCCEEDED(s.As(&s3))) s3->put_AreBrowserAcceleratorKeysEnabled(FALSE);

                            ComPtr<ICoreWebView2_3> w3;
                            if (SUCCEEDED(g_web.As(&w3))) {
                                std::wstring web = ExeDir() + L"\\web";
                                w3->SetVirtualHostNameToFolderMapping(kAppHost, web.c_str(),
                                                                      COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW);
                            }
                            g_web->AddScriptToExecuteOnDocumentCreated(L"window.MDHost = 'win';", nullptr);

                            EventRegistrationToken tok;
                            g_web->add_WebMessageReceived(
                                Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                    [](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
                                        LPWSTR json = nullptr;
                                        if (SUCCEEDED(args->get_WebMessageAsJson(&json)) && json) {
                                            OnMessage(JsonParser::Parse(json));
                                            CoTaskMemFree(json);
                                        }
                                        return S_OK;
                                    }).Get(), &tok);
                            g_web->add_NavigationStarting(
                                Callback<ICoreWebView2NavigationStartingEventHandler>(
                                    [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
                                        LPWSTR uri = nullptr;
                                        if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
                                            if (HandleNavigation(uri)) args->put_Cancel(TRUE);
                                            CoTaskMemFree(uri);
                                        }
                                        return S_OK;
                                    }).Get(), &tok);
                            g_web->add_NewWindowRequested(
                                Callback<ICoreWebView2NewWindowRequestedEventHandler>(
                                    [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
                                        args->put_Handled(TRUE);
                                        LPWSTR uri = nullptr;
                                        if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
                                            HandleNavigation(uri);
                                            CoTaskMemFree(uri);
                                        }
                                        return S_OK;
                                    }).Get(), &tok);
                            g_web->add_ProcessFailed(
                                Callback<ICoreWebView2ProcessFailedEventHandler>(
                                    [](ICoreWebView2* sender, ICoreWebView2ProcessFailedEventArgs*) -> HRESULT {
                                        g_ready = false;
                                        sender->Reload();
                                        return S_OK;
                                    }).Get(), &tok);

                            RECT rc;
                            GetClientRect(g_hwnd, &rc);
                            g_ctrl->put_Bounds(rc);

                            if (g_path.empty()) {
                                ShowStartPage();
                            } else {
                                MapDocumentHost();
                                g_web->Navigate((L"https://" + std::wstring(kAppHost) + L"/index.html").c_str());
                            }
                            return S_OK;
                        }).Get());
            }).Get());
    if (FAILED(hr)) {
        MessageBoxW(g_hwnd, L"无法启动 WebView2 / Could not start WebView2.", L"MDReader", MB_ICONERROR);
    }
}

// ---------------------------------------------------------------- window procedure

void SavePlacement() {
    WINDOWPLACEMENT wp{sizeof(wp)};
    if (!GetWindowPlacement(g_hwnd, &wp)) return;
    RECT& r = wp.rcNormalPosition;
    wchar_t buf[96];
    swprintf(buf, 96, L"%ld,%ld,%ld,%ld,%d", r.left, r.top, r.right, r.bottom, wp.showCmd == SW_SHOWMAXIMIZED ? 1 : 0);
    RegSet(L"placement", buf);
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_SIZE:
        if (g_ctrl) {
            RECT rc;
            GetClientRect(hwnd, &rc);
            g_ctrl->put_Bounds(rc);
        }
        return 0;
    case WM_MOVE:
    case WM_MOVING:
        if (g_ctrl) g_ctrl->NotifyParentWindowPositionChanged();
        break;
    case WM_DPICHANGED: {
        const RECT* r = reinterpret_cast<const RECT*>(lp);
        SetWindowPos(hwnd, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_TIMER:
        if (wp == kSaveTimer) {
            SaveNow();
        } else if (wp == kWatchTimer && !g_path.empty() && !g_dirty) {
            FILETIME t = WriteTime(g_path);
            if (CompareFileTime(&t, &g_mtime) != 0 && LoadFile(g_path)) Render(true);
        }
        return 0;
    case WM_ACTIVATE:
        if (LOWORD(wp) != WA_INACTIVE && g_path.empty() && g_ready) SendRecents();
        break;
    case WM_CLOSE:
        if (!SaveNow() && MessageBoxW(hwnd, L"文件未保存，仍要关闭吗？\nThe file could not be saved. Close anyway?",
                                      L"MDReader", MB_YESNO | MB_ICONWARNING) != IDYES) return 0;
        SavePlacement();
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        g_ctrl.Reset();
        g_web.Reset();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv && argc > 1) {
        wchar_t full[MAX_PATH * 2];
        if (GetFullPathNameW(argv[1], MAX_PATH * 2, full, nullptr) && FileExists(full) && LoadFile(full)) {
            g_path = full;
            NoteRecent(g_path);
        }
    }
    if (argv) LocalFree(argv);

    COLORREF bg = ParseColor(RegGet(L"lastBG", L"#ffffff"), RGB(255, 255, 255));
    WNDCLASSEXW wc{sizeof(wc)};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
    wc.hIconSm = LoadIconW(inst, MAKEINTRESOURCEW(1));
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = CreateSolidBrush(bg);
    wc.lpszClassName = kWindowClass;
    RegisterClassExW(&wc);

    // Restore the last window placement, cascading a little for each extra window.
    int x = CW_USEDEFAULT, y = CW_USEDEFAULT, w = 1100, h = 780;
    bool maximized = false;
    std::wstring pl = RegGet(L"placement", L"");
    long l, t, r, b;
    int mx = 0;
    if (swscanf_s(pl.c_str(), L"%ld,%ld,%ld,%ld,%d", &l, &t, &r, &b, &mx) == 5 && r - l > 300 && b - t > 200) {
        int offset = FindWindowW(kWindowClass, nullptr) ? 28 : 0;
        x = l + offset; y = t + offset; w = r - l; h = b - t;
        maximized = mx == 1;
    }

    g_hwnd = CreateWindowExW(0, kWindowClass, L"MDReader", WS_OVERLAPPEDWINDOW, x, y, w, h,
                             nullptr, nullptr, inst, nullptr);
    if (!g_hwnd) return 1;
    UpdateTitle();
    ShowWindow(g_hwnd, maximized ? SW_SHOWMAXIMIZED : show);
    UpdateWindow(g_hwnd);
    SetTimer(g_hwnd, kWatchTimer, 1000, nullptr);
    InitWebView();

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    CoUninitialize();
    return static_cast<int>(msg.wParam);
}

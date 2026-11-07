// Minimal JSON reader/writer for the WebView2 message bridge.
#pragma once
#include <map>
#include <string>
#include <vector>

struct JVal {
    enum Type { Null, Bool, Num, Str, Obj, Arr } type = Null;
    bool b = false;
    double n = 0;
    std::wstring s;
    std::map<std::wstring, JVal> o;
    std::vector<JVal> a;

    const JVal& operator[](const std::wstring& key) const {
        static const JVal none;
        auto it = o.find(key);
        return it == o.end() ? none : it->second;
    }
    std::wstring str(const std::wstring& def = L"") const { return type == Str ? s : def; }
    bool boolean(bool def = false) const { return type == Bool ? b : def; }
    double num(double def = 0) const { return type == Num ? n : def; }
};

class JsonParser {
public:
    static JVal Parse(const std::wstring& text) {
        JsonParser p(text.c_str());
        p.ws();
        return p.value();
    }

private:
    explicit JsonParser(const wchar_t* s) : p_(s) {}
    const wchar_t* p_;

    void ws() { while (*p_ == L' ' || *p_ == L'\t' || *p_ == L'\n' || *p_ == L'\r') ++p_; }

    JVal value() {
        ws();
        JVal v;
        if (*p_ == L'{') {
            v.type = JVal::Obj; ++p_; ws();
            if (*p_ == L'}') { ++p_; return v; }
            while (*p_) {
                ws();
                std::wstring key = string();
                ws(); if (*p_ == L':') ++p_;
                v.o[key] = value();
                ws();
                if (*p_ == L',') { ++p_; continue; }
                if (*p_ == L'}') { ++p_; break; }
                break;
            }
        } else if (*p_ == L'[') {
            v.type = JVal::Arr; ++p_; ws();
            if (*p_ == L']') { ++p_; return v; }
            while (*p_) {
                v.a.push_back(value());
                ws();
                if (*p_ == L',') { ++p_; continue; }
                if (*p_ == L']') { ++p_; break; }
                break;
            }
        } else if (*p_ == L'"') {
            v.type = JVal::Str; v.s = string();
        } else if (wcsncmp(p_, L"true", 4) == 0) {
            v.type = JVal::Bool; v.b = true; p_ += 4;
        } else if (wcsncmp(p_, L"false", 5) == 0) {
            v.type = JVal::Bool; v.b = false; p_ += 5;
        } else if (wcsncmp(p_, L"null", 4) == 0) {
            p_ += 4;
        } else {
            wchar_t* end = nullptr;
            v.type = JVal::Num; v.n = wcstod(p_, &end);
            p_ = end && end != p_ ? end : p_ + 1;
        }
        return v;
    }

    std::wstring string() {
        std::wstring out;
        if (*p_ != L'"') return out;
        ++p_;
        while (*p_ && *p_ != L'"') {
            if (*p_ == L'\\') {
                ++p_;
                switch (*p_) {
                case L'n': out += L'\n'; break;
                case L'r': out += L'\r'; break;
                case L't': out += L'\t'; break;
                case L'b': out += L'\b'; break;
                case L'f': out += L'\f'; break;
                case L'u': {
                    unsigned cp = 0;
                    for (int i = 1; i <= 4 && p_[i]; ++i) {
                        wchar_t c = p_[i];
                        cp = cp * 16 + (c >= L'0' && c <= L'9' ? c - L'0' : (c | 0x20) - L'a' + 10);
                    }
                    out += static_cast<wchar_t>(cp);
                    p_ += 4;
                    break;
                }
                case 0: return out;
                default: out += *p_; break;
                }
                ++p_;
            } else {
                out += *p_++;
            }
        }
        if (*p_ == L'"') ++p_;
        return out;
    }
};

/// JSON string literal (with quotes) for injecting values into scripts.
inline std::wstring JsonStr(const std::wstring& s) {
    std::wstring out = L"\"";
    for (wchar_t c : s) {
        switch (c) {
        case L'"': out += L"\\\""; break;
        case L'\\': out += L"\\\\"; break;
        case L'\n': out += L"\\n"; break;
        case L'\r': out += L"\\r"; break;
        case L'\t': out += L"\\t"; break;
        case 0x2028: out += L"\\u2028"; break;
        case 0x2029: out += L"\\u2029"; break;
        default:
            if (c < 0x20) {
                wchar_t buf[8];
                swprintf(buf, 8, L"\\u%04x", static_cast<unsigned>(c));
                out += buf;
            } else {
                out += c;
            }
        }
    }
    return out + L"\"";
}

inline std::wstring JsonBool(bool b) { return b ? L"true" : L"false"; }

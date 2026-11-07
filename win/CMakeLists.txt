cmake_minimum_required(VERSION 3.20)
project(MDReader LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Static CRT: no Visual C++ redistributable needed on the user's machine.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(WEBVIEW2_DIR "" CACHE PATH "Root of the extracted Microsoft.Web.WebView2 NuGet package")

add_compile_definitions(UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_compile_options("$<$<COMPILE_LANGUAGE:CXX>:/utf-8;/W3;/O1;/GL>")
add_link_options(/LTCG /OPT:REF /OPT:ICF)

add_executable(MDReader WIN32 MDReader/main.cpp MDReader/app.rc)
target_include_directories(MDReader PRIVATE "${WEBVIEW2_DIR}/build/native/include")
target_link_libraries(MDReader PRIVATE
  "${WEBVIEW2_DIR}/build/native/x64/WebView2LoaderStatic.lib"
  shlwapi dwmapi comdlg32 shell32 ole32 oleaut32 advapi32 user32 gdi32 version)
target_link_options(MDReader PRIVATE /MANIFEST:NO)

add_library(MDReaderThumb SHARED Thumbnail/ThumbProvider.cpp Thumbnail/ThumbProvider.def)
target_link_libraries(MDReaderThumb PRIVATE gdiplus shlwapi ole32 uuid)

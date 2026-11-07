; MDReader for Windows — Inno Setup script (per-user install, no admin rights needed).
; Build: iscc /DAppVersion=1.0.0 /DStage=<folder with MDReader.exe, MDReaderThumb.dll, web\> MDReader.iss

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef Stage
  #define Stage "..\..\build\win-stage"
#endif
; "{{" escapes the brace: these expand to {GUID} in the registry.
#define ThumbCLSIDKey "{{12A87F8B-65AB-49E4-A3B5-F60AE714B4E9}"
#define ThumbnailShellEx "{{e357fccd-a995-4576-b01f-234630154e96}"

[Setup]
AppId={{6F1D2E3A-8C4B-4C55-9E3B-2B7C1A9D0E41}
AppName=MDReader
AppVersion={#AppVersion}
AppVerName=MDReader {#AppVersion}
AppPublisher=MDReader
AppPublisherURL=https://github.com/x2724009/MDReader
AppSupportURL=https://github.com/x2724009/MDReader/issues
DefaultDirName={localappdata}\Programs\MDReader
DefaultGroupName=MDReader
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=yes
OutputDir=..\..\dist
OutputBaseFilename=MDReader-{#AppVersion}-win-x64-setup
SetupIconFile=..\MDReader\res\app.ico
UninstallDisplayIcon={app}\MDReader.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "thumbs"; Description: "在资源管理器中显示 Markdown 缩略图 / Markdown thumbnails in Explorer"; Flags: checkedonce

[Files]
Source: "{#Stage}\MDReader.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\MDReaderThumb.dll"; DestDir: "{app}"; Flags: ignoreversion restartreplace uninsrestartdelete
Source: "{#Stage}\web\*"; DestDir: "{app}\web"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Stage}\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\MDReader"; Filename: "{app}\MDReader.exe"
Name: "{autodesktop}\MDReader"; Filename: "{app}\MDReader.exe"; Tasks: desktopicon

[Registry]
; ProgID + "Open with"
Root: HKA; Subkey: "Software\Classes\MDReader.Markdown"; ValueType: string; ValueName: ""; ValueData: "Markdown Document"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\MDReader.Markdown\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\MDReader.exe,1"
Root: HKA; Subkey: "Software\Classes\MDReader.Markdown\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\MDReader.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\.md\OpenWithProgids"; ValueType: string; ValueName: "MDReader.Markdown"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.markdown\OpenWithProgids"; ValueType: string; ValueName: "MDReader.Markdown"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\MDReader.exe\SupportedTypes"; ValueType: string; ValueName: ".md"; ValueData: ""; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\MDReader.exe\SupportedTypes"; ValueType: string; ValueName: ".markdown"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\MDReader.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\MDReader.exe"" ""%1"""
; Thumbnail handler (COM, per user)
Root: HKA; Subkey: "Software\Classes\CLSID\{#ThumbCLSIDKey}"; ValueType: string; ValueName: ""; ValueData: "MDReader Markdown Thumbnail"; Tasks: thumbs; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\CLSID\{#ThumbCLSIDKey}"; ValueType: dword; ValueName: "DisableProcessIsolation"; ValueData: "0"; Tasks: thumbs
Root: HKA; Subkey: "Software\Classes\CLSID\{#ThumbCLSIDKey}\InprocServer32"; ValueType: string; ValueName: ""; ValueData: "{app}\MDReaderThumb.dll"; Tasks: thumbs
Root: HKA; Subkey: "Software\Classes\CLSID\{#ThumbCLSIDKey}\InprocServer32"; ValueType: string; ValueName: "ThreadingModel"; ValueData: "Apartment"; Tasks: thumbs
Root: HKA; Subkey: "Software\Classes\.md\ShellEx\{#ThumbnailShellEx}"; ValueType: string; ValueName: ""; ValueData: "{#ThumbCLSIDKey}"; Tasks: thumbs; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\.markdown\ShellEx\{#ThumbnailShellEx}"; ValueType: string; ValueName: ""; ValueData: "{#ThumbCLSIDKey}"; Tasks: thumbs; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved"; ValueType: string; ValueName: "{#ThumbCLSIDKey}"; ValueData: "MDReader Markdown Thumbnail"; Tasks: thumbs; Flags: uninsdeletevalue
; Settings
Root: HKCU; Subkey: "Software\MDReader"; Flags: uninsdeletekeyifempty

[Run]
Filename: "{app}\MDReader.exe"; Description: "{cm:LaunchProgram,MDReader}"; Flags: nowait postinstall skipifsilent

[Code]
function WebView2Installed(): Boolean;
var
  Version: String;
begin
  Result :=
    (RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0')) or
    (RegQueryStringValue(HKCU, 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ErrorCode: Integer;
begin
  if (CurStep = ssPostInstall) and (not WebView2Installed()) then
  begin
    if MsgBox('MDReader 需要 Microsoft Edge WebView2 运行时（Windows 10/11 通常已自带）。现在打开下载页面吗？' + #13#10 +
              'MDReader needs the Microsoft Edge WebView2 Runtime. Open the download page now?',
              mbConfirmation, MB_YESNO) = IDYES then
      ShellExec('open', 'https://go.microsoft.com/fwlink/p/?LinkId=2124703', '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
  end;
end;

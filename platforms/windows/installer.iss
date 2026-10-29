#define AppName "ClipMesh"
#define AppVersion "0.3.0"
[Setup]
AppId={{4BDB9E47-45A6-41BC-9B2C-A3928738448D}
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\ClipMesh
DefaultGroupName=ClipMesh
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=ClipMesh-Windows-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\ClipMesh.exe
CloseApplications=yes
RestartApplications=no
[Files]
; First in the solid archive: the NEW helper must run before installed files
; are overwritten. Its sidecar libraries stay beside it in the temporary tree.
Source: "..\..\dist\windows\*"; DestDir: "{tmp}\ClipMesh-update"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "..\..\dist\windows\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "ClipMesh"; ValueData: """{app}\ClipMesh.exe"" --background"; Flags: uninsdeletevalue
[Icons]
Name: "{autoprograms}\ClipMesh"; Filename: "{app}\ClipMesh.exe"
[Run]
Filename: "{app}\ClipMesh.exe"; Description: "Open ClipMesh"; Flags: nowait postinstall skipifsilent

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  Helper: String;
begin
  Result := '';
  try
    ExtractTemporaryFiles('{tmp}\ClipMesh-update\*');
    Helper := ExpandConstant('{tmp}\ClipMesh-update\ClipMesh.exe');
    if not Exec(Helper, '--prepare-update --install-dir ' + AddQuotes(ExpandConstant('{app}')),
      ExtractFileDir(Helper), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      Result := 'ClipMesh update preparation could not start. Close ClipMesh and retry.'
    else if ResultCode <> 0 then
      Result := 'ClipMesh could not stop the running app or release its files. Close ClipMesh and retry. No installed files have been replaced.';
  except
    Result := 'ClipMesh update preparation could not be extracted. No installed files have been replaced.';
  end;
end;

function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
  Helper: String;
begin
  Helper := ExpandConstant('{app}\ClipMesh.exe');
  Result := Exec(Helper, '--prepare-update --install-dir ' + AddQuotes(ExpandConstant('{app}')),
    ExtractFileDir(Helper), SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if Result then Result := ResultCode = 0;
  if not Result then
    MsgBox('ClipMesh could not stop the running app or release its files. Close ClipMesh and retry. Uninstall has not removed any files.', mbError, MB_OK);
end;

Unicode true
!include "MUI2.nsh"
Name "ClipMesh"
VIProductVersion "0.3.0.0"
VIAddVersionKey /LANG=1033 "ProductName" "ClipMesh"
VIAddVersionKey /LANG=1033 "FileVersion" "0.3.0"
VIAddVersionKey /LANG=1033 "ProductVersion" "0.3.0"
VIAddVersionKey /LANG=1033 "FileDescription" "ClipMesh Setup"
VIAddVersionKey /LANG=1033 "LegalCopyright" "ClipMesh contributors"
!ifdef CLIPMESH_SETUP_OUTPUT
OutFile "${CLIPMESH_SETUP_OUTPUT}"
!else
OutFile "../../dist/ClipMesh-Windows-Setup.exe"
!endif
InstallDir "$LOCALAPPDATA\Programs\ClipMesh"
RequestExecutionLevel user
SetCompressor /SOLID lzma
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\ClipMesh.exe"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
Section "ClipMesh"
  ; Always use the NEW helper, outside the directory being replaced. Older
  ; installed versions do not understand --prepare-update and may show a GUI.
  InitPluginsDir
  SetOutPath "$PLUGINSDIR\ClipMesh-update"
  File /r "../../dist/windows/*"
  prepare_retry:
  ClearErrors
  StrCpy $0 -1
  ExecWait '$\"$PLUGINSDIR\ClipMesh-update\ClipMesh.exe$\" --prepare-update --install-dir $\"$INSTDIR$\"' $0
  IfErrors prepare_failed
  IntCmp $0 0 prepare_done prepare_failed prepare_failed
  prepare_failed:
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "ClipMesh could not stop the running app or release its files. Close ClipMesh and retry. No installed files have been replaced." /SD IDCANCEL IDRETRY prepare_retry
  Abort
  prepare_done:
  SetOutPath "$INSTDIR"
  File /r "../../dist/windows/*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  ; Enable the requested reboot/login recovery; the app UI can turn this off.
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "ClipMesh" '$\"$INSTDIR\ClipMesh.exe$\" --background'
  CreateDirectory "$SMPROGRAMS\ClipMesh"
  CreateShortcut "$SMPROGRAMS\ClipMesh\ClipMesh.lnk" "$INSTDIR\ClipMesh.exe"
  CreateShortcut "$SMPROGRAMS\ClipMesh\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipMesh" "DisplayName" "ClipMesh"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipMesh" "DisplayVersion" "0.3.0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipMesh" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipMesh" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipMesh" "NoRepair" 1
SectionEnd
Section "Uninstall"
  ; The helper exits before deletion and excludes its own process from shutdown.
  uninstall_prepare_retry:
  ClearErrors
  StrCpy $0 -1
  ExecWait '$\"$INSTDIR\ClipMesh.exe$\" --prepare-update --install-dir $\"$INSTDIR$\"' $0
  IfErrors uninstall_prepare_failed
  IntCmp $0 0 uninstall_prepare_done uninstall_prepare_failed uninstall_prepare_failed
  uninstall_prepare_failed:
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "ClipMesh could not stop the running app or release its files. Close ClipMesh and retry. Uninstall has not removed any files." /SD IDCANCEL IDRETRY uninstall_prepare_retry
  Abort
  uninstall_prepare_done:
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "ClipMesh"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipMesh"
  RMDir /r "$SMPROGRAMS\ClipMesh"
  RMDir /r "$INSTDIR"
  ; User config/key/history remains in LocalAppData\ClipMesh for deliberate recovery.
SectionEnd

Unicode true

!ifndef APP_SOURCE
  !error "APP_SOURCE must point to the Flutter Windows Release directory"
!endif
!ifndef APP_VERSION
  !define APP_VERSION "0.1.5"
!endif

Name "FerryPane"
OutFile "FerryPane-windows-x64-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\FerryPane"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName" "FerryPane"
VIAddVersionKey "FileDescription" "FerryPane Windows Setup"
VIAddVersionKey "FileVersion" "${APP_VERSION}"

!include "MUI2.nsh"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Russian"
!insertmacro MUI_LANGUAGE "English"

Section "FerryPane" SecInstall
  SetOutPath "$INSTDIR"
  File /r "${APP_SOURCE}\*"
  CreateDirectory "$SMPROGRAMS\FerryPane"
  CreateShortCut "$SMPROGRAMS\FerryPane\FerryPane.lnk" "$INSTDIR\ferrypane.exe"
  CreateShortCut "$DESKTOP\FerryPane.lnk" "$INSTDIR\ferrypane.exe"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FerryPane" "DisplayName" "FerryPane"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FerryPane" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FerryPane" "Publisher" "FerryPane Contributors"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FerryPane" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FerryPane" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FerryPane" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FerryPane" "NoRepair" 1
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\FerryPane.lnk"
  Delete "$SMPROGRAMS\FerryPane\FerryPane.lnk"
  RMDir "$SMPROGRAMS\FerryPane"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FerryPane"
SectionEnd

; Emberlight Companion installer hooks (bundle.windows.nsis.installerHooks in tauri.conf.json).
;
; Tauri's own "is the app running?" check asks the Windows Restart Manager and stops the whole
; install ("Failed to kill Emberlight Companion. Please close it first then try again") when it
; cannot close what it finds. On some PCs it finds something even though the Companion is not
; running (nothing in Task Manager, a manual uninstall and a fresh download fail the same way),
; and then the member can never update.
;
; This file replaces that check (same name, so the installer and the uninstaller both use it)
; with one that never stops the install:
;   1. ask Windows to end any Emberlight Companion.exe by its file name; "none running" is fine;
;   2. if the old program file is still there, delete it; if something still holds it (a virus
;      scanner, an Explorer preview), move it aside instead (a file in use can be renamed), so the
;      new file can be written; the leftover is removed on the next install or at restart.
; If the file really cannot be replaced, the installer says so on that step, as any installer does.
;
; The hooks file is included after Tauri's utils.nsh, so the original macro exists and can be undefined.
; Keep the macro name and its two parameters: installer.nsi calls it as
; `CheckIfAppIsRunning "$INSTDIR\<main exe>" "<product name>"`.

!macroundef CheckIfAppIsRunning
!macro CheckIfAppIsRunning executablePath productName
  Push $0

  DetailPrint "Closing ${productName} if it is open"
  ; Exit code 128 means no such process: that is fine. No /T, so a game started from the app is left alone.
  nsExec::Exec '"$SYSDIR\taskkill.exe" /F /IM "${MAINBINARYNAME}.exe"'
  Pop $0
  Sleep 1000

  ; Remove what an earlier install had to move aside.
  Delete "${executablePath}.old"

  ClearErrors
  Delete "${executablePath}"
  ${If} ${FileExists} "${executablePath}"
    ; Still there, so something holds it. A file in use can be renamed even when it cannot be deleted.
    DetailPrint "${executablePath} is in use, moving it aside"
    Rename "${executablePath}" "${executablePath}.old"
    Delete /REBOOTOK "${executablePath}.old"
  ${EndIf}

  Pop $0
!macroend

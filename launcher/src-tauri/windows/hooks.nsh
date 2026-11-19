; Uninstalling also removes the "start with Windows" entry added by the
; autostart plugin (the launcher re-adds it at each start while installed).
!macro NSIS_HOOK_PREUNINSTALL
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${PRODUCTNAME}"
!macroend

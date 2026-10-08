; Throwaway coloured window used by the tests.
; Usage: AutoHotkeyU64.exe testwin.ahk <title> <rrggbb>
#NoEnv
#SingleInstance, Off
title = %1%
color = %2%
if (color = "")
    color := "336699"
Gui, +Resize +MinSize200x120
Gui, Color, %color%
Gui, Font, s28 Bold
Gui, Add, Text, x16 y16 w420 cWhite BackgroundTrans, %title%
Gui, Show, w520 h320, %title%
return

GuiClose:
ExitApp

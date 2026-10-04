on run argv
    set volumeFolder to POSIX file (item 1 of argv) as alias
    tell application "Finder"
        open volumeFolder
        delay 1
        set installWindow to container window of volumeFolder
        set savedOptions to icon view options of installWindow
        if current view of installWindow is not icon view then error "Install window is not in icon view"
        if icon size of savedOptions is not 112 then error "Install icon size was not preserved"
        if position of item "Illiquid.app" of volumeFolder is not {190, 234} then error "Illiquid icon position was not preserved"
        if position of item "Applications" of volumeFolder is not {530, 234} then error "Applications icon position was not preserved"
        close installWindow
    end tell
end run

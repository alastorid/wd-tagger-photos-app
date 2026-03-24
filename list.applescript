#!/usr/bin/osascript

tell application "Photos"
    set outLines to {}

    set rootAlbums to albums

    repeat with a in rootAlbums
        set nm to name of a as text
        set end of outLines to nm
    end repeat
end tell

set AppleScript's text item delimiters to linefeed
set joined to outLines as text
set AppleScript's text item delimiters to ""
set sorted to paragraphs of (do shell script "printf %s " & quoted form of joined & " | /usr/bin/sort")

set AppleScript's text item delimiters to linefeed
set finalText to sorted as text
set AppleScript's text item delimiters to ""

return finalText

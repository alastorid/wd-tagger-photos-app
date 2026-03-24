#!/usr/bin/osascript
-- Usage:
-- osascript tagger.applescript "album" "smile"
property RAMDISK_NAME : "ramdisk"
property RAMDISK_MB : 256
property MAX_KEYWORDS : 64
property PROGRESS_EVERY : 10
property BATCH_SIZE : 16
property ALBUM_FLUSH_EVERY : 64
property g_pendingTriggerAdds : {}
property g_pendingNoTriggerAdds : {}
property TAGGER_URL : "http://127.0.0.1:5566"

on run argv
    if (count of argv) < 1 then
        error "Usage: osascript tagger.applescript <source_album> [trigger_keyword]"
    end if

    set SOURCE_ALBUM to item 1 of argv
    set TRIGGER_KEYWORD to ""
    if (count of argv) >= 2 then
        set TRIGGER_KEYWORD to item 2 of argv
    end if

    set t0 to (current date)
    my ramdiskCleanup()
    my ramdiskMount(RAMDISK_MB, RAMDISK_NAME)

    tell application "Photos"
        set srcAlbum to my getAlbumByName(SOURCE_ALBUM)
        if srcAlbum is missing value then error "Album not found: " & SOURCE_ALBUM
        set itemsList to media items of srcAlbum
        set n to count of itemsList
    end tell

    log ("Start album='" & SOURCE_ALBUM & "' items=" & n & " trigger='" & TRIGGER_KEYWORD & "'")

    set taggedCount to 0
    set skippedVideoCount to 0
    set alreadyTaggedCount to 0
    set triggerAddedCount to 0
    set errorCount to 0

    set triggerAlbumRef to missing value
    set noTriggerAlbumRef to missing value

    if TRIGGER_KEYWORD is not "" then
        set albumName to SOURCE_ALBUM

        set triggerFolderName to TRIGGER_KEYWORD
        set noTriggerFolderName to "no-" & TRIGGER_KEYWORD

        set triggerFolderRef to my ensureFolderAtRoot(triggerFolderName)
        set noTriggerFolderRef to my ensureFolderAtRoot(noTriggerFolderName)

        set triggerAlbumRef to my ensureAlbumInFolder(triggerFolderRef, albumName)
        set noTriggerAlbumRef to my ensureAlbumInFolder(noTriggerFolderRef, albumName)
    end if

    set pendingItems to {}
    set g_pendingTriggerAdds to {}
    set g_pendingNoTriggerAdds to {}

    repeat with i from 1 to n
        try
            tell application "Photos"
                set mi to item i of itemsList
                set kwList to keywords of mi
            end tell
            if kwList is missing value then set kwList to {}

            -- Treat video as nothing: skip completely
            if my isVideoMediaItem(mi) then
                set skippedVideoCount to skippedVideoCount + 1
            else
                -- Only tag when keywords missing
                if (count of kwList) = 0 or my hasValidKeyword(kwList) is false then
                    set tmpPath to my exportItemLowRes(mi)

                    if tmpPath is "" then
                        my bumpError("exportItemLowRes returned empty; i=" & i, "export produced no file (maybe iCloud still downloading)", -1)
                    else if my isVideoPath(tmpPath) then
                        set skippedVideoCount to skippedVideoCount + 1
                        my safeCleanup(tmpPath)
                    else
                        my waitForFile(tmpPath, 2)

                        set hintKey to my hintPathWithRetry(tmpPath, 3)
                        if hintKey is "" then
                            my bumpError("hintPathWithRetry i=" & i, "hint returned empty key", -1)
                            my safeCleanup(tmpPath)
                        else
                            -- enqueue: map path -> cache key
                            set end of pendingItems to {mi:mi, p:tmpPath, k:hintKey}

                            -- when reach batch size, process batch
                            if (count of pendingItems) >= BATCH_SIZE then
                                set taggedNow to my processPendingBatch(pendingItems, MAX_KEYWORDS, TRIGGER_KEYWORD)
                                set taggedCount to taggedCount + taggedNow
                                set pendingItems to {}
                            end if
                        end if
                    end if
                else
                    -- Clean duplicated original keywords
                    set cleanedKW to my dedupeIfNeeded(kwList)

                    if cleanedKW is not kwList then
                        tell application "Photos"
                            set keywords of mi to cleanedKW
                        end tell
                        set kwList to cleanedKW
                    end if

                    set alreadyTaggedCount to alreadyTaggedCount + 1

                    if TRIGGER_KEYWORD is not "" then
                        tell application "Photos" to set kwNow to keywords of mi
                        if kwNow is missing value then set kwNow to {}
                        if my listContains(kwNow, TRIGGER_KEYWORD) then
                            set end of g_pendingTriggerAdds to mi
                            set triggerAddedCount to triggerAddedCount + 1
                        else
                            set end of g_pendingNoTriggerAdds to mi
                        end if
                    end if
                end if
            end if

            if (i mod PROGRESS_EVERY) = 0 then
                my logProgress(i, n, taggedCount, alreadyTaggedCount, skippedVideoCount, triggerAddedCount, errorCount, t0)
            end if

            if (i mod ALBUM_FLUSH_EVERY) = 0 then
                my flushAlbumAdds(triggerAlbumRef, noTriggerAlbumRef, g_pendingTriggerAdds, g_pendingNoTriggerAdds)
                set g_pendingTriggerAdds to {}
                set g_pendingNoTriggerAdds to {}
            end if

        on error errMsg number errNum
            set miId to ""
            try
                tell application "Photos" to set miId to id of mi
            end try

            my bumpError("[" & i & "/" & n & "] miId=" & miId, errMsg, errNum)
        end try
    end repeat

    if (count of pendingItems) > 0 then
        set taggedNow to my processPendingBatch(pendingItems, MAX_KEYWORDS, TRIGGER_KEYWORD)
        set taggedCount to taggedCount + taggedNow
        set pendingItems to {}
    end if

    set triggerAddedCount to triggerAddedCount + (count of g_pendingTriggerAdds)
    my flushAlbumAdds(triggerAlbumRef, noTriggerAlbumRef, g_pendingTriggerAdds, g_pendingNoTriggerAdds)
    set g_pendingTriggerAdds to {}
    set g_pendingNoTriggerAdds to {}

    my logProgress(n, n, taggedCount, alreadyTaggedCount, skippedVideoCount, triggerAddedCount, errorCount, t0)
    my ramdiskCleanup()
    log "Done."
end run


-- ===== Helpers =====
on hintPathWithRetry(p, maxTries)
    log (". >> hintPathWithRetry")

    repeat with attempt from 1 to maxTries
        try
            set jsonBody to "{\"paths\":[" & my jsonQuote(p) & "]}"

            set cmd to "curl --show-error --max-time 60 -sS -f " & ¬
                "-H 'Content-Type: application/json' -H 'Accept: text/plain' " & ¬
                (quoted form of (TAGGER_URL & "/hint?fmt=us")) & " " & ¬
                "-d " & quoted form of jsonBody

            set outText to my trimWhitespace(do shell script cmd)

            if outText is not "" then
                log (". << hintPathWithRetry key=" & outText)
                return outText
            end if
        on error errMsg
            if attempt = maxTries then
                log ("hintPathWithRetry failed for " & p & " : " & errMsg)
                return ""
            end if
            delay 0.12
        end try
    end repeat

    return ""
end hintPathWithRetry

on dedupeIfNeeded(xs)
    if xs is missing value then return {}

    set out to {}
    set seen to {}
    set hadDup to false

    repeat with x in xs
        set s to my trimWhitespace(x as text)
        if s is not "" then
            if my listContains(seen, s) then
                set hadDup to true
            else
                set end of seen to s
                set end of out to s
            end if
        end if
    end repeat

    if hadDup then
        return out
    else
        return xs
    end if
end dedupeIfNeeded

on bumpError(contextText, errMsg, errNum)
    log ("ERROR " & contextText & " :: " & errMsg & " (" & errNum & ")")
end bumpError

on ensureFolder(folderName)
    tell application "Photos"
        try
            return folder named folderName
        on error
            return make new folder named folderName
        end try
    end tell
end ensureFolder

on ensureFolderAtRoot(folderName)
    tell application "Photos"
        try
            return folder named folderName
        on error
            return make new folder named folderName
        end try
    end tell
end ensureFolderAtRoot

on ensureAlbumInFolder(folderRef, albumName)
    tell application "Photos"
        try
            return album named albumName of folderRef
        on error
            return make new album named albumName at folderRef
        end try
    end tell
end ensureAlbumInFolder


on isVideoMediaItem(mi)
    try
        tell application "Photos"
            set fn to ""
            try
                set fn to filename of mi
            end try
            set kd to ""
            try
                set kd to (kind of mi) as text
            end try
        end tell

        set fnL to my toLower(fn)
        set kdL to my toLower(kd)

        if fnL ends with ".mov" or fnL ends with ".mp4" or fnL ends with ".m4v" then return true
        if kdL contains "video" then return true
        return false
    on error
        return false
    end try
end isVideoMediaItem

property g_validKeywords : {}
property g_validKeywordsLoaded : false
on isInvalidKeyword(k)
    set s to my trimWhitespace(k as text)
    if s is "" then return true

    set sLower to my toLower(s)

    -- obvious junk first
    if sLower starts with "http" then return true
    if sLower contains ".com" then return true
    if sLower contains ".net" then return true
    if sLower contains ".org" then return true
    if sLower contains ".xyz" then return true
    if sLower contains ".vip" then return true
    if sLower contains ".top" then return true
    if sLower contains ".info" then return true
    if sLower contains ".one" then return true
    if sLower contains ".pl" then return true

    -- lazy-load valid keyword list once
    if g_validKeywordsLoaded is false then
        try
            set cmd to "curl --show-error --max-time 20 -sS -f " & ¬
                "-H 'Accept: text/plain' " & ¬
                quoted form of (TAGGER_URL & "/selected_tags?fmt=us")

            set outText to do shell script cmd

            if outText is not "" then
                set AppleScript's text item delimiters to (character id 31)
                set g_validKeywords to text items of outText
                set AppleScript's text item delimiters to ""
            else
                set g_validKeywords to {}
            end if
        on error errMsg
            log ("isInvalidKeyword: failed to load /selected_tags : " & errMsg)
            set g_validKeywords to {}
        end try

        set g_validKeywordsLoaded to true
        log ("isInvalidKeyword: loaded valid keyword count=" & (count of g_validKeywords))
    end if

    -- if we have server tag list, use exact membership check
    if (count of g_validKeywords) > 0 then
        if my listContains(g_validKeywords, s) then
            return false
        else
            return true
        end if
    end if

    -- fallback if server unavailable: keep old loose behavior
    return false
end isInvalidKeyword

on hasValidKeyword(kwList)
    if kwList is missing value then return false

    repeat with k in kwList
        set s to k as text
        if s is not "" then
            if my isInvalidKeyword(s) is false then
                return true
            end if
        end if
    end repeat

    return false
end hasValidKeyword

on processPendingBatch(pendingItems, maxKeywords, triggerKeyword)
    log (". >> processPendingBatch batch=" & (count of pendingItems))

    set keyList to {}
    repeat with rec in pendingItems
        set end of keyList to (k of rec)
    end repeat

    set tagLines to my tagBatchWithRetry(keyList, 3)
    if tagLines is missing value then set tagLines to {}

    set taggedNow to 0
    set m to (count of pendingItems)

    set writeItems to {}

    repeat with idx from 1 to m
        set one to item idx of pendingItems
        set mi to (mi of one)
        set tmpPath to (p of one)
        set hintKey to (k of one)

        set tagString to ""
        if idx <= (count of tagLines) then set tagString to (item idx of tagLines)

        if tagString is "" then
            log ("processPendingBatch: empty tag for key=" & hintKey & " path=" & tmpPath)
            my safeCleanup(tmpPath)
        else
            set newKW to my parseTags(tagString)
            set newKW to my takeFirstN(newKW, maxKeywords)
            set end of writeItems to {mi:mi, p:tmpPath, k:hintKey, kw:newKW}
        end if
    end repeat

    if (count of writeItems) = 0 then
        log (". << processPendingBatch taggedNow=0")
        return 0
    end if

    set tBatch0 to (current date)

    try
        tell application "Photos"
            repeat with rec in writeItems
                set mi to (mi of rec)
                set tmpPath to (p of rec)
                set hintKey to (k of rec)
                set newKW to (kw of rec)

                try
                    set tOne0 to (current date)
                    set keywords of mi to newKW
                    set tOne1 to (current date)

                    log ("processPendingBatch: single keyword write key=" & hintKey & " dt=" & ((tOne1 - tOne0) as real) & "s")

                    set taggedNow to taggedNow + 1

                    if triggerKeyword is not "" then
                        if my listContains(newKW, triggerKeyword) then
                            set end of g_pendingTriggerAdds to mi
                        else
                            set end of g_pendingNoTriggerAdds to mi
                        end if
                    end if
                on error errMsg number errNum
                    log ("processPendingBatch: single keyword write failed key=" & hintKey & " path=" & tmpPath & " :: " & errMsg & " (" & errNum & ")")
                end try
            end repeat
        end tell
    end try

    set tBatch1 to (current date)
    log ("processPendingBatch: photos keyword phase dt=" & ((tBatch1 - tBatch0) as real) & "s count=" & (count of writeItems))

    repeat with rec in writeItems
        my safeCleanup(p of rec)
    end repeat

    log (". << processPendingBatch taggedNow=" & taggedNow)
    return taggedNow
end processPendingBatch

on flushAlbumAdds(triggerAlbumRef, noTriggerAlbumRef, pendingTriggerAdds, pendingNoTriggerAdds)
    if triggerAlbumRef is missing value and noTriggerAlbumRef is missing value then return

    tell application "Photos"
        try
            if triggerAlbumRef is not missing value then
                if (count of pendingTriggerAdds) > 0 then
                    add pendingTriggerAdds to triggerAlbumRef
                end if
            end if
        on error errMsg number errNum
            log ("flushAlbumAdds(trigger) failed: " & errMsg & " (" & errNum & ")")
        end try

        try
            if noTriggerAlbumRef is not missing value then
                if (count of pendingNoTriggerAdds) > 0 then
                    add pendingNoTriggerAdds to noTriggerAlbumRef
                end if
            end if
        on error errMsg number errNum
            log ("flushAlbumAdds(no-trigger) failed: " & errMsg & " (" & errNum & ")")
        end try
    end tell
end flushAlbumAdds

on splitByUnitSep(s)
    if s is "" then return {}
    set AppleScript's text item delimiters to (character id 31)
    set xs to text items of s
    set AppleScript's text item delimiters to ""
    return xs
end splitByUnitSep

on tagBatchWithRetry(keys, maxTries)
    log (". >> tagBatchWithRetry batch=" & (count of keys))

    repeat with attempt from 1 to maxTries
        try
            set jsonBody to my jsonBodyForKeys(keys)

            set cmd to "curl --show-error --max-time 120 -sS -f " & ¬
                "-H 'Content-Type: application/json' -H 'Accept: text/plain' " & ¬
                (quoted form of (TAGGER_URL & "/tag_batch?fmt=us")) & " " & ¬
                "-d " & quoted form of jsonBody

            set outText to do shell script cmd

            set AppleScript's text item delimiters to (character id 31)
            set tagList to text items of outText
            set AppleScript's text item delimiters to ""

            log (". << tagBatchWithRetry")
            return tagList
        on error errMsg
            if attempt = maxTries then
                log ("tagBatchWithRetry failed: " & errMsg)
                return {}
            end if
            delay 0.12
        end try
    end repeat

    return {}
end tagBatchWithRetry

on jsonBodyForPaths(paths)
    -- builds: {"paths":[...], "batch":4}
    set arr to my jsonArrayOfStrings(paths)
    return "{\"paths\":" & arr & ",\"batch\":" & (BATCH_SIZE as text) & "}"
end jsonBodyForPaths

on jsonBodyForKeys(keys)
    -- builds: {"keys":[...], "batch":16}
    set arr to my jsonArrayOfStrings(keys)
    return "{\"keys\":" & arr & ",\"batch\":" & (BATCH_SIZE as text) & "}"
end jsonBodyForKeys

on jsonArrayOfStrings(xs)
    set parts to {}
    repeat with x in xs
        set end of parts to my jsonQuote(x as text)
    end repeat

    set AppleScript's text item delimiters to ","
    set s to parts as text
    set AppleScript's text item delimiters to ""
    return "[" & s & "]"
end jsonArrayOfStrings

on splitLines(s)
    if s is "" then return {}
    set AppleScript's text item delimiters to (character id 10)
    set xs to text items of s
    set AppleScript's text item delimiters to ""
    return xs
end splitLines

on tagWithRetry(p, maxTries)
    log (". >> tagWithRetry")

    repeat with attempt from 1 to maxTries
        try
            set jsonBody to "{\"path\":" & my jsonQuote(p) & "}"
            set cmd to "curl -sS -f http://127.0.0.1:7788/tag -H 'Content-Type: application/json' -d " & quoted form of jsonBody & " | python3 -c " & quoted form of "import sys,json; o=json.load(sys.stdin); print(o.get('tags',''))"
            set out to do shell script cmd
            if out is not "" then
                log (". << tagWithRetry")
                return out
            end if
        on error errMsg
            if attempt = maxTries then
                log ("Retry failed for " & p & " : " & errMsg)
                return ""
            end if
            delay 0.1
        end try
    end repeat
    return ""
end tagWithRetry

on jsonQuote(s)
    set py to "import json,sys; print(json.dumps(sys.argv[1]))"
    return do shell script "python3 -c " & quoted form of py & " " & quoted form of s
end jsonQuote

on imageIsDecodable(p)
    try
        do shell script "/usr/bin/sips -g pixelWidth -g pixelHeight " & quoted form of p & " >/dev/null"
        return true
    on error
        return false
    end try
end imageIsDecodable

on restartPhotosGracefully()
    log (">> restartPhotosGracefully")

    tell application "Photos"
        if it is running then
            quit
        end if
    end tell

    repeat 50 times
        tell application "System Events"
            if not (exists process "Photos") then exit repeat
        end tell
        delay 0.2
    end repeat

    tell application "Photos"
        activate
    end tell

    repeat 50 times
        tell application "System Events"
            if exists process "Photos" then exit repeat
        end tell
        delay 0.2
    end repeat

    delay 2

    log ("<< restartPhotosGracefully")
end restartPhotosGracefully

on waitForExportReady(exportDir, timeoutSec)
    log (". >> waitForExportReady")

    set t0 to (current date)
    set tFind0 to (current date)

    set p to my newestNonDotFileRecursive(exportDir)

    repeat
        set nowT to (current date)
        set elapsed to nowT - t0
        if elapsed > timeoutSec then
            log ("waitForExportReady: TIMEOUT after " & (elapsed as integer) & "s exportDir=" & exportDir)
            log (". << waitForExportReady")
            return ""
        end if

        if p is "" then
            set findElapsed to nowT - tFind0
            if findElapsed > 3 then
                my restartPhotosGracefully()
                log ("waitForExportReady: FAIL no file found after " & (findElapsed as integer) & "s exportDir=" & exportDir)
                log (". << waitForExportReady")
                return ""
            end if

            log (". .. elapsed=" & elapsed & " findElapsed=" & findElapsed)
            set p to my newestNonDotFileRecursive(exportDir)
            delay 0.23
        else
            if my imageIsDecodable(p) then
                log ("waitForExportReady: READY file=" & p)
                log (". << waitForExportReady")
                return p
            end if

            set p to my newestNonDotFileRecursive(exportDir)
            delay 0.23
        end if
    end repeat
end waitForExportReady

on waitForFile(p, timeoutSec)
    log (". >> waitForFile")

    set t0 to (current date)
    repeat
        try
            do shell script "test -f " & quoted form of p
            exit repeat
        on error
            if ((current date) - t0) > timeoutSec then exit repeat
            delay 0.1
        end try
    end repeat
    log (". << waitForFile")
end waitForFile

on logProgress(i, n, taggedCount, alreadyTaggedCount, skippedVideoCount, triggerAddedCount, errorCount, t0)
    set dt to (current date) - t0
    log ("Progress " & i & "/" & n & " | tagged=" & taggedCount & " already=" & alreadyTaggedCount & " skippedVideo=" & skippedVideoCount & " triggerAdded=" & triggerAddedCount & " errors=" & errorCount & " | elapsed=" & (dt as integer) & "s")
end logProgress

on getAlbumByName(albumName)
    tell application "Photos"
        try
            return album named albumName
        on error
            return missing value
        end try
    end tell
end getAlbumByName

on ensureAlbum(albumName)
    tell application "Photos"
        try
            return album named albumName
        on error
            return make new album named albumName
        end try
    end tell
end ensureAlbum

on newestNonDotFileRecursive(exportDir)
    log (". >> newestNonDotFileRecursive")

    try
        set py to "
import os, sys
root = sys.argv[1]
newest = ''
newest_m = -1
for dp, dns, fns in os.walk(root):
    for fn in fns:
        if fn.startswith('.'):
            continue
        p = os.path.join(dp, fn)
        try:
            st = os.stat(p)
            if os.path.isfile(p) and st.st_mtime > newest_m:
                newest_m = st.st_mtime
                newest = p
        except:
            pass
print(newest)
"
        set cmd to "/usr/bin/python3 -c " & quoted form of py & space & quoted form of exportDir
        set p to do shell script cmd
        if p is "" then
            log (". << newestNonDotFileRecursive")
            return ""
        end if
        log (". << newestNonDotFileRecursive")
        return p
    on error
        log (". << newestNonDotFileRecursive")
        return ""
    end try
end newestNonDotFileRecursive

on exportItemLowRes(mi)
    set baseDir to ""
    set exportDir to ""
    set outPath to ""

    log (". >> exportItemLowRes")

    -- 1) Prepare export dir
    try
        set baseDir to my ramdiskPathOrTemp()
        if baseDir is "" then
            log "exportItemLowRes: baseDir is empty"
            return ""
        end if

        if baseDir does not end with "/" then set baseDir to baseDir & "/"

        set exportDir to baseDir & "wd_export_" & (do shell script "/usr/bin/uuidgen") & "/"
        do shell script "/bin/mkdir -p " & quoted form of exportDir
    on error errMsg number errNum
        log ("exportItemLowRes: mkdir/setup failed baseDir=" & baseDir & " :: " & errMsg & " (" & errNum & ")")
        return ""
    end try

    -- 2) Export via Photos
    tell application "Photos"
        try
            export {mi} to POSIX file exportDir
        on error errMsg number errNum
            log ("exportItemLowRes: Photos export failed exportDir=" & exportDir & " :: " & errMsg & " (" & errNum & ")")
            return ""
        end try
    end tell

    try
        set outPath to my waitForExportReady(exportDir, 300, 2)
    on error errMsg number errNum
        log ("exportItemLowRes: newestNonDotFile failed exportDir=" & exportDir & " :: " & errMsg & " (" & errNum & ")")
        return ""
    end try

    if outPath is "" then
        try
            set ls to do shell script "/bin/ls -la " & quoted form of exportDir & " 2>/dev/null | /usr/bin/tail -n +1"
            log ("exportItemLowRes: exportDir empty or not ready (async/iCloud). exportDir=" & exportDir)
            log ("exportItemLowRes: dir listing:\n" & ls)
        on error
            log ("exportItemLowRes: outPath empty; also failed to list exportDir=" & exportDir)
        end try
        return ""
    end if

    log (". << exportItemLowRes")

    return outPath
end exportItemLowRes

on ramdiskMount(sizeMB, volName)
    -- If already mounted, do nothing
    set mp to "/Volumes/" & volName
    try
        do shell script "test -d " & quoted form of mp
        return
    end try

    set sectors to (sizeMB * 2048)

    -- Create + format + mount
    set cmd to "diskutil erasevolume HFS+ " & quoted form of volName & " `hdiutil attach -nomount ram://" & sectors & "` >/dev/null"
    do shell script cmd
end ramdiskMount

on ramdiskCleanup()
    set mp to "/Volumes/" & RAMDISK_NAME
    try
        do shell script "diskutil eject " & quoted form of mp & " >/dev/null 2>&1 || true"
    end try
end ramdiskCleanup

on ramdiskPathOrTemp()
    set mp to "/Volumes/" & RAMDISK_NAME & "/"
    try
        do shell script "test -d " & quoted form of mp
        return mp
    on error
        return (POSIX path of (path to temporary items))
    end try
end ramdiskPathOrTemp

on safeCleanup(filePath)
    try
        do shell script "test -f " & quoted form of filePath & " && rm -f " & quoted form of filePath
    end try
    try
        set d to do shell script "dirname " & quoted form of filePath
        do shell script "rmdir " & quoted form of d & " 2>/dev/null || true"
    end try
end safeCleanup

on isVideoPath(p)
    set lp to my toLower(p as text)
    if lp ends with ".mov" then return true
    if lp ends with ".mp4" then return true
    if lp ends with ".m4v" then return true
    return false
end isVideoPath

on parseTags(tagString)
    set AppleScript's text item delimiters to ","
    set rawItems to text items of tagString
    set AppleScript's text item delimiters to ""

    set cleaned to {}
    repeat with t in rawItems
        set s to my trimWhitespace(t as text)
        if s is not "" then set end of cleaned to s
    end repeat
    return cleaned
end parseTags

on takeFirstN(xs, n)
    if xs is missing value then return {}
    if (count of xs) <= n then return xs
    set out to {}
    repeat with j from 1 to n
        set end of out to item j of xs
    end repeat
    return out
end takeFirstN

on listContains(xs, needle)
    if xs is missing value then return false
    repeat with x in xs
        if (x as text) is (needle as text) then return true
    end repeat
    return false
end listContains

on trimWhitespace(s)
    set s to s as text
    set sp to " "
    set tb to (character id 9)
    set lf to (character id 10)
    set cr to (character id 13)

    repeat while s is not "" and (s begins with sp or s begins with tb or s begins with lf or s begins with cr)
        if (length of s) = 1 then
            set s to ""
        else
            set s to text 2 thru -1 of s
        end if
    end repeat

    repeat while s is not "" and (s ends with sp or s ends with tb or s ends with lf or s ends with cr)
        if (length of s) = 1 then
            set s to ""
        else
            set s to text 1 thru -2 of s
        end if
    end repeat

    return s
end trimWhitespace

on toLower(s)
    set upperChars to "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    set lowerChars to "abcdefghijklmnopqrstuvwxyz"
    set out to s

    repeat with i from 1 to length of upperChars
        set out to my replaceText(character i of upperChars, character i of lowerChars, out)
    end repeat

    return out
end toLower

on replaceText(findText, replaceText, sourceText)
    set AppleScript's text item delimiters to findText
    set parts to text items of sourceText
    set AppleScript's text item delimiters to replaceText
    set newText to parts as text
    set AppleScript's text item delimiters to ""
    return newText
end replaceText

#!/usr/bin/osascript
use framework "Foundation"
use scripting additions

-- Extract every video frame through a bounded RAM-disk buffer and retain frames
-- whose WD tags match at least one supplied regular expression.
--
-- Usage:
--   ./extract_frame_by_tag.applescript video.mp4 'looks_at_viewer'
--   ./extract_frame_by_tag.applescript video.mp4 'eyes.+' 'smile|grin'
--   ./extract_frame_by_tag.applescript video.mp4 '__EYES__'

property TAGGER_URL : "http://127.0.0.1:5566"
property RAMDISK_MB : 512
property RAMDISK_NAME : "ramdisk"
property RAMDISK_MOUNT_LOCK : "/tmp/wd-tagger-ramdisk-mount.lock"
property BATCH_SIZE : 16
property POLL_SECONDS : 0.10
property MAX_RETRIES : 3
property g_compiledRegexes : {}
property g_eyesPreset : false
property g_eyeEvidenceRegex : missing value

on run argv
    if (count of argv) < 2 then
        error "Usage: ./extract_frame_by_tag.applescript <video> <tag-regex> [tag-regex ...]"
    end if

    set videoPath to my absoluteExistingFile(item 1 of argv)
    set regexes to items 2 thru -1 of argv
    my prepareMatchers(regexes)
    my requireTagger()

    set ffmpegPath to my findExecutable("ffmpeg")
    set outputDir to my outputDirectoryFor(videoPath)
    my prepareOutputDirectory(outputDir)

    set runID to do shell script "/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]'"
    set mountPath to "/Volumes/" & RAMDISK_NAME
    set workDir to mountPath & "/wd-frame-extractor/" & runID
    set bufferDir to workDir & "/frames"
    set pidFile to workDir & "/ffmpeg.pid"
    set doneFile to workDir & "/ffmpeg.done"
    set logFile to workDir & "/ffmpeg.log"
    set producerPID to ""
    set producerStopped to false
    set processedCount to 0
    set matchedCount to 0

    try
        my ensureRamdisk(RAMDISK_MB, RAMDISK_NAME, mountPath)
        my cleanupStaleWorkdirs(mountPath & "/wd-frame-extractor")
        do shell script "/bin/mkdir -p " & quoted form of bufferDir
        my writeOwnerPID(workDir)
        log ("Using shared RAM buffer at " & mountPath)

        set producerPID to my startFFmpeg(ffmpegPath, videoPath, bufferDir, pidFile, doneFile, logFile)
        log ("Started video=" & videoPath & " patterns=" & my joinText(regexes, ", "))
        log ("Output=" & outputDir & " RAM buffer=" & mountPath & " ffmpeg_pid=" & producerPID)

        repeat
            set producerDone to my fileExists(doneFile)
            set framePaths to my bufferedFrames(bufferDir)
            set frameCount to count of framePaths

            -- While FFmpeg is active, its newest visible JPEG may still be open.
            -- Stop it and consume only completed frames preceding that file.
            if producerDone is false and frameCount > BATCH_SIZE then
                if producerStopped is false then
                    my signalProcess(producerPID, "STOP")
                    set producerStopped to true
                    delay 0.05
                    set framePaths to my bufferedFrames(bufferDir)
                    set frameCount to count of framePaths
                end if

                set safeCount to frameCount - 1
                if safeCount > BATCH_SIZE then set safeCount to BATCH_SIZE
                if safeCount > 0 then
                    set batchPaths to items 1 thru safeCount of framePaths
                    set resultCounts to my processFrameBatch(batchPaths, outputDir)
                    set processedCount to processedCount + item 1 of resultCounts
                    set matchedCount to matchedCount + item 2 of resultCounts
                    log ("Progress frames=" & processedCount & " matches=" & matchedCount)
                end if

                if producerStopped then
                    my signalProcess(producerPID, "CONT")
                    set producerStopped to false
                end if
            else if producerDone and frameCount > 0 then
                set takeCount to frameCount
                if takeCount > BATCH_SIZE then set takeCount to BATCH_SIZE
                set batchPaths to items 1 thru takeCount of framePaths
                set resultCounts to my processFrameBatch(batchPaths, outputDir)
                set processedCount to processedCount + item 1 of resultCounts
                set matchedCount to matchedCount + item 2 of resultCounts
                log ("Progress frames=" & processedCount & " matches=" & matchedCount)
            else if producerDone and frameCount = 0 then
                exit repeat
            else
                delay POLL_SECONDS
            end if
        end repeat

        set ffmpegStatus to my readTextFile(doneFile)
        if ffmpegStatus is not "0" then
            set ffmpegLog to my readTextFile(logFile)
            error "FFmpeg failed with exit code " & ffmpegStatus & ": " & ffmpegLog
        end if

        my cleanupWorkdir(workDir)
        log ("Done. Scanned " & processedCount & " frames; copied " & matchedCount & " matches to " & outputDir)
        return outputDir
    on error errMsg number errNum
        if producerPID is not "" then
            if producerStopped then my signalProcess(producerPID, "CONT")
            my signalProcess(producerPID, "TERM")
        end if
        my cleanupWorkdir(workDir)
        error errMsg number errNum
    end try
end run

on processFrameBatch(framePaths, outputDir)
    set inferencePaths to {}
    repeat with framePath in framePaths
        set sourcePath to framePath as text
        set inferencePath to sourcePath & ".wd-input.jpg"
        do shell script "/bin/ln " & quoted form of sourcePath & " " & quoted form of inferencePath
        set end of inferencePaths to inferencePath
    end repeat

    try
        set keys to my hintBatchWithRetry(inferencePaths, MAX_RETRIES)
        if (count of keys) is not (count of framePaths) then error "Tagger returned the wrong number of preload keys"

        set tagLines to my tagBatchWithRetry(keys, MAX_RETRIES)
        if (count of tagLines) is not (count of framePaths) then error "Tagger returned the wrong number of tag results"

        set matchFlags to my regexMatchFlags(tagLines)
        if (count of matchFlags) is not (count of framePaths) then error "Regex matcher returned the wrong number of results"

        set matchedNow to 0
        repeat with i from 1 to count of framePaths
            set framePath to item i of framePaths
            if item i of matchFlags is "1" then
                do shell script "/bin/cp -p " & quoted form of framePath & " " & quoted form of outputDir & "/"
                set matchedNow to matchedNow + 1
            end if
            do shell script "/bin/rm -f " & quoted form of framePath
        end repeat
        return {(count of framePaths), matchedNow}
    on error errMsg number errNum
        repeat with inferencePath in inferencePaths
            try
                do shell script "/bin/rm -f " & quoted form of (inferencePath as text)
            end try
        end repeat
        error errMsg number errNum
    end try
end processFrameBatch

on hintBatchWithRetry(paths, maxTries)
    set bodyText to "{\"paths\":" & my jsonArrayOfStrings(paths) & "}"
    repeat with attempt from 1 to maxTries
        try
            set cmd to "/usr/bin/curl --show-error --max-time 120 -sS -f " & ¬
                "-H 'Content-Type: application/json' -H 'Accept: text/plain' " & ¬
                quoted form of (TAGGER_URL & "/hint?fmt=us") & " -d " & quoted form of bodyText
            return my splitUnitSeparator(do shell script cmd)
        on error errMsg number errNum
            if attempt = maxTries then error "Tagger preload failed: " & errMsg number errNum
            delay 0.15
        end try
    end repeat
end hintBatchWithRetry

on tagBatchWithRetry(keys, maxTries)
    set bodyText to "{\"keys\":" & my jsonArrayOfStrings(keys) & ",\"batch\":" & BATCH_SIZE & "}"
    repeat with attempt from 1 to maxTries
        try
            set cmd to "/usr/bin/curl --show-error --max-time 180 -sS -f " & ¬
                "-H 'Content-Type: application/json' -H 'Accept: text/plain' " & ¬
                quoted form of (TAGGER_URL & "/tag_batch?fmt=us") & " -d " & quoted form of bodyText
            set resultText to do shell script cmd
            return my splitUnitSeparatorPreservingEmpty(resultText, count of keys)
        on error errMsg number errNum
            if attempt = maxTries then error "Tagger inference failed: " & errMsg number errNum
            delay 0.15
        end try
    end repeat
end tagBatchWithRetry

on regexMatchFlags(tagLines)
    set flags to {}
    repeat with tagLine in tagLines
        set tags to my parseTagLine(tagLine as text)
        set regularMatch to false
        set hasEyeEvidence to false

        repeat with oneTag in tags
            set tagText to oneTag as text
            set underscoreTag to my replaceText(tagText, " ", "_")

            if g_eyesPreset then
                if my regexMatches(g_eyeEvidenceRegex, tagText) then set hasEyeEvidence to true
            end if

            if regularMatch is false then
                repeat with regexObject in g_compiledRegexes
                    if my regexMatches(regexObject, tagText) or my regexMatches(regexObject, underscoreTag) then
                        set regularMatch to true
                        exit repeat
                    end if
                end repeat
            end if
        end repeat

        if regularMatch or (g_eyesPreset and hasEyeEvidence) then
            set end of flags to "1"
        else
            set end of flags to "0"
        end if
    end repeat
    return flags
end regexMatchFlags

on prepareMatchers(regexes)
    set g_compiledRegexes to {}
    set g_eyesPreset to false

    repeat with patternText in regexes
        set onePattern to patternText as text
        if onePattern is "__EYES__" then
            set g_eyesPreset to true
        else
            set end of g_compiledRegexes to my compileFullRegex(onePattern)
        end if
    end repeat

    if g_eyesPreset then
        set g_eyeEvidenceRegex to my compileFullRegex("(?:.* )?eyes(?: .*)?|(?:.* )?eye(?: .*)?|wide-eyed|(?:long |thick )?eyelashes|eyepatch|medical eyepatch|blindfold|black blindfold")
    end if
end prepareMatchers

on compileFullRegex(patternText)
    set regexObject to current application's NSRegularExpression's regularExpressionWithPattern:("\\A(?:" & patternText & ")\\z") options:0 |error|:(missing value)
    if regexObject is missing value then error "Invalid tag regular expression: " & patternText
    return regexObject
end compileFullRegex

on regexMatches(regexObject, inputText)
    set nsText to current application's NSString's stringWithString:inputText
    set searchRange to current application's NSMakeRange(0, nsText's |length|())
    set matchRange to regexObject's rangeOfFirstMatchInString:nsText options:0 range:searchRange
    return (matchRange's |length|) > 0
end regexMatches

on parseTagLine(tagLine)
    set AppleScript's text item delimiters to ","
    set rawTags to text items of tagLine
    set AppleScript's text item delimiters to ""
    set tags to {}
    repeat with rawTag in rawTags
        set cleanTag to my trimWhitespace(rawTag as text)
        set cleanTag to my replaceText(cleanTag, "\\(", "(")
        set cleanTag to my replaceText(cleanTag, "\\)", ")")
        if cleanTag is not "" then set end of tags to cleanTag
    end repeat
    return tags
end parseTagLine

on requireTagger()
    try
        do shell script "/usr/bin/curl --max-time 3 -sS -f " & quoted form of (TAGGER_URL & "/health") & " >/dev/null"
    on error
        error "WD tagger is not reachable at " & TAGGER_URL & ". Start wd_daemon/run.sh first."
    end try
end requireTagger

on startFFmpeg(ffmpegPath, videoPath, bufferDir, pidFile, doneFile, logFile)
    set destination to bufferDir & "/frame_%012d.jpg"
    set ffmpegCmd to quoted form of ffmpegPath & " -hide_banner -loglevel error -i " & quoted form of videoPath & ¬
        " -map 0:v:0 -fps_mode passthrough -q:v 2 -start_number 1 -y " & quoted form of destination
    set workerCmd to ffmpegCmd & " >" & quoted form of logFile & " 2>&1 & " & ¬
        "ffpid=$!; /bin/echo $ffpid >" & quoted form of pidFile & "; " & ¬
        "wait $ffpid; /bin/echo $? >" & quoted form of doneFile
    do shell script "/usr/bin/nohup /bin/sh -c " & quoted form of workerCmd & " </dev/null >/dev/null 2>&1 &"

    repeat with i from 1 to 100
        if my fileExists(pidFile) then return my readTextFile(pidFile)
        delay 0.02
    end repeat
    set debugListing to ""
    try
        set debugListing to do shell script "/bin/ls -la " & quoted form of (do shell script "/usr/bin/dirname " & quoted form of pidFile)
    end try
    error "Could not obtain FFmpeg process ID; worker directory: " & debugListing
end startFFmpeg

on bufferedFrames(bufferDir)
    set cmd to "/usr/bin/find " & quoted form of bufferDir & " -maxdepth 1 -type f -name 'frame_*.jpg' ! -name '*.wd-input.jpg' -print | /usr/bin/sort"
    set resultText to do shell script cmd
    if resultText is "" then return {}
    return my splitLinesPreservingEmpty(resultText)
end bufferedFrames

on signalProcess(pidText, signalName)
    try
        do shell script "/bin/kill -" & signalName & " " & quoted form of pidText & " 2>/dev/null || true"
    end try
end signalProcess

on ensureRamdisk(sizeMB, volumeName, mountPath)
    if my isMountedVolume(mountPath) then
        my verifyRamdiskWritable(mountPath)
        return
    end if

    set ownsLock to false
    repeat with attempt from 1 to 100
        try
            do shell script "/bin/mkdir " & quoted form of RAMDISK_MOUNT_LOCK
            do shell script "/bin/echo $PPID > " & quoted form of (RAMDISK_MOUNT_LOCK & "/owner-pid")
            set ownsLock to true
            exit repeat
        on error
            if my isMountedVolume(mountPath) then
                my verifyRamdiskWritable(mountPath)
                return
            end if
            set lockPID to my readTextFile(RAMDISK_MOUNT_LOCK & "/owner-pid")
            if lockPID is not "" then
                try
                    do shell script "/bin/kill -0 " & quoted form of lockPID & " 2>/dev/null"
                on error
                    do shell script "/bin/rm -rf " & quoted form of RAMDISK_MOUNT_LOCK
                end try
            end if
            delay 0.05
        end try
    end repeat
    if ownsLock is false then error "Timed out waiting to create shared RAM disk at " & mountPath

    try
        if my isMountedVolume(mountPath) is false then
            set sectors to sizeMB * 2048
            set cmd to "device=$(/usr/bin/hdiutil attach -nomount ram://" & sectors & " | /usr/bin/awk 'NR==1 {print $1}'); " & ¬
                "/bin/test -n \"$device\" || exit 1; " & ¬
                "if ! /usr/sbin/diskutil erasevolume HFS+ " & quoted form of volumeName & " \"$device\" >/dev/null; then " & ¬
                "/usr/bin/hdiutil detach \"$device\" >/dev/null 2>&1 || true; exit 1; fi"
            do shell script cmd
        end if
        my verifyRamdiskWritable(mountPath)
        do shell script "/bin/rm -rf " & quoted form of RAMDISK_MOUNT_LOCK
    on error errMsg number errNum
        do shell script "/bin/rm -rf " & quoted form of RAMDISK_MOUNT_LOCK
        error "Could not prepare shared RAM disk: " & errMsg number errNum
    end try
end ensureRamdisk

on isMountedVolume(mountPath)
    try
        do shell script "/usr/sbin/diskutil info " & quoted form of mountPath & " 2>/dev/null | /usr/bin/grep -Eq '^ *Mounted: +Yes$'"
        return true
    on error
        return false
    end try
end isMountedVolume

on verifyRamdiskWritable(mountPath)
    set probePath to mountPath & "/.wd-write-test-" & (do shell script "/usr/bin/uuidgen")
    do shell script "/usr/bin/touch " & quoted form of probePath & " && /bin/rm -f " & quoted form of probePath
end verifyRamdiskWritable

on writeOwnerPID(workDir)
    do shell script "/bin/echo $PPID > " & quoted form of (workDir & "/.owner-pid")
end writeOwnerPID

on cleanupStaleWorkdirs(workRoot)
    try
        do shell script "/bin/mkdir -p " & quoted form of workRoot
        set dirText to do shell script "/usr/bin/find " & quoted form of workRoot & " -mindepth 1 -maxdepth 1 -type d -print"
        if dirText is "" then return
        repeat with oneDir in paragraphs of dirText
            set dirPath to oneDir as text
            set ownerFile to dirPath & "/.owner-pid"
            set ownerPID to my readTextFile(ownerFile)
            -- A missing owner file can mean another invocation just created
            -- the directory and has not written its PID yet. Leave it alone.
            if ownerPID is not "" then
                try
                    do shell script "/bin/kill -0 " & quoted form of ownerPID & " 2>/dev/null"
                on error
                    do shell script "/bin/rm -rf " & quoted form of dirPath
                end try
            end if
        end repeat
    end try
end cleanupStaleWorkdirs

on cleanupWorkdir(workDir)
    try
        do shell script "/bin/rm -rf " & quoted form of workDir
    end try
end cleanupWorkdir

on prepareOutputDirectory(outputDir)
    do shell script "/bin/mkdir -p " & quoted form of outputDir
    set existing to do shell script "/usr/bin/find " & quoted form of outputDir & " -maxdepth 1 -type f -name 'frame_*.jpg' -print -quit"
    if existing is not "" then error "Output directory already contains generated frames: " & outputDir
end prepareOutputDirectory

on outputDirectoryFor(videoPath)
    set nsPath to current application's NSString's stringWithString:videoPath
    set parentPath to nsPath's stringByDeletingLastPathComponent()
    set fileStem to (nsPath's lastPathComponent()'s stringByDeletingPathExtension()) as text
    return (parentPath's stringByAppendingPathComponent:(fileStem & "_frames")) as text
end outputDirectoryFor

on absoluteExistingFile(inputPath)
    set nsPath to current application's NSString's stringWithString:inputPath
    set nsPath to nsPath's stringByExpandingTildeInPath()
    if not (nsPath's isAbsolutePath()) then
        set currentDir to current application's NSFileManager's defaultManager()'s currentDirectoryPath()
        set nsPath to currentDir's stringByAppendingPathComponent:nsPath
    end if
    set nsPath to nsPath's stringByStandardizingPath()'s stringByResolvingSymlinksInPath()
    if not (current application's NSFileManager's defaultManager()'s fileExistsAtPath:nsPath) then
        error "Video file does not exist: " & inputPath
    end if
    return nsPath as text
end absoluteExistingFile

on findExecutable(toolName)
    try
        return do shell script "/bin/zsh -lc " & quoted form of ("command -v " & toolName)
    on error
        error toolName & " was not found on PATH"
    end try
end findExecutable

on fileExists(filePath)
    try
        do shell script "/bin/test -f " & quoted form of filePath
        return true
    on error
        return false
    end try
end fileExists

on readTextFile(filePath)
    try
        return do shell script "/bin/cat " & quoted form of filePath
    on error
        return ""
    end try
end readTextFile

on splitUnitSeparator(s)
    if s is "" then return {}
    set AppleScript's text item delimiters to character id 31
    set xs to text items of s
    set AppleScript's text item delimiters to ""
    return xs
end splitUnitSeparator

on splitUnitSeparatorPreservingEmpty(s, expectedCount)
    if expectedCount = 1 and s is "" then return {""}
    set xs to my splitUnitSeparator(s)
    repeat while (count of xs) < expectedCount
        set end of xs to ""
    end repeat
    return xs
end splitUnitSeparatorPreservingEmpty

on splitLinesPreservingEmpty(s)
    if s is "" then return {""}
    return paragraphs of s
end splitLinesPreservingEmpty

on jsonArrayOfStrings(xs)
    set parts to {}
    repeat with x in xs
        set end of parts to my jsonQuote(x as text)
    end repeat
    return "[" & my joinText(parts, ",") & "]"
end jsonArrayOfStrings

on jsonQuote(s)
    set escapedText to s as text
    set escapedText to my replaceText(escapedText, "\\", "\\\\")
    set escapedText to my replaceText(escapedText, "\"", "\\\"")
    set escapedText to my replaceText(escapedText, character id 8, "\\b")
    set escapedText to my replaceText(escapedText, character id 12, "\\f")
    set escapedText to my replaceText(escapedText, return, "\\r")
    set escapedText to my replaceText(escapedText, linefeed, "\\n")
    set escapedText to my replaceText(escapedText, tab, "\\t")
    return "\"" & escapedText & "\""
end jsonQuote

on replaceText(sourceText, searchText, replacementText)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to searchText
    set textParts to text items of sourceText
    set AppleScript's text item delimiters to replacementText
    set resultText to textParts as text
    set AppleScript's text item delimiters to oldDelimiters
    return resultText
end replaceText

on trimWhitespace(s)
    set whitespace to {" ", tab, return, linefeed}
    set resultText to s as text
    repeat while resultText is not "" and first character of resultText is in whitespace
        if (count of characters of resultText) = 1 then return ""
        set resultText to text 2 thru -1 of resultText
    end repeat
    repeat while resultText is not "" and last character of resultText is in whitespace
        if (count of characters of resultText) = 1 then return ""
        set resultText to text 1 thru -2 of resultText
    end repeat
    return resultText
end trimWhitespace

on joinText(xs, delimiterText)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to delimiterText
    set resultText to xs as text
    set AppleScript's text item delimiters to oldDelimiters
    return resultText
end joinText

#!/usr/bin/osascript
-- Extract every video frame through a bounded RAM-disk buffer and retain frames
-- whose WD tags match at least one supplied regular expression.
--
-- Usage:
--   ./extract_frame_by_tag.applescript video.mp4 'looks_at_viewer'
--   ./extract_frame_by_tag.applescript video.mp4 'eyes.+' 'smile|grin'
--   ./extract_frame_by_tag.applescript video.mp4 '__EYES__'

property TAGGER_URL : "http://127.0.0.1:5566"
property RAMDISK_MB : 512
property BATCH_SIZE : 16
property POLL_SECONDS : 0.10
property MAX_RETRIES : 3

on run argv
    if (count of argv) < 2 then
        error "Usage: ./extract_frame_by_tag.applescript <video> <tag-regex> [tag-regex ...]"
    end if

    set videoPath to my absoluteExistingFile(item 1 of argv)
    set regexes to items 2 thru -1 of argv
    my validateRegexes(regexes)
    my requireTagger()

    set ffmpegPath to my findExecutable("ffmpeg")
    set outputDir to my outputDirectoryFor(videoPath)
    my prepareOutputDirectory(outputDir)

    set runID to do shell script "/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]'"
    set volumeName to "wd-frames-" & text 1 thru 8 of runID
    set mountPath to "/Volumes/" & volumeName
    set bufferDir to mountPath & "/frames"
    set pidFile to mountPath & "/ffmpeg.pid"
    set doneFile to mountPath & "/ffmpeg.done"
    set logFile to mountPath & "/ffmpeg.log"
    set producerPID to ""
    set producerStopped to false
    set processedCount to 0
    set matchedCount to 0

    try
        my mountRamdisk(RAMDISK_MB, volumeName)
        do shell script "/bin/mkdir -p " & quoted form of bufferDir
        log ("Mounted RAM buffer at " & mountPath)

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
                    set resultCounts to my processFrameBatch(batchPaths, regexes, outputDir)
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
                set resultCounts to my processFrameBatch(batchPaths, regexes, outputDir)
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

        my unmountRamdisk(mountPath)
        log ("Done. Scanned " & processedCount & " frames; copied " & matchedCount & " matches to " & outputDir)
        return outputDir
    on error errMsg number errNum
        if producerPID is not "" then
            if producerStopped then my signalProcess(producerPID, "CONT")
            my signalProcess(producerPID, "TERM")
        end if
        my unmountRamdisk(mountPath)
        error errMsg number errNum
    end try
end run

on processFrameBatch(framePaths, regexes, outputDir)
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

        set matchFlags to my regexMatchFlags(tagLines, regexes)
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

on regexMatchFlags(tagLines, regexes)
    set payload to "{\"patterns\":" & my jsonArrayOfStrings(regexes) & ",\"tags\":" & my jsonArrayOfStrings(tagLines) & "}"
    set py to "import json,re,sys; o=json.loads(sys.argv[1]); preset='__EYES__' in o['patterns']; rs=[re.compile(x) for x in o['patterns'] if x != '__EYES__']; " & ¬
        "clean=lambda s:s.replace('\\\\(', '(').replace('\\\\)', ')'); " & ¬
        "eye=re.compile(r'(?:.* )?eyes(?: .*)?|(?:.* )?eye(?: .*)?|wide-eyed|(?:long |thick )?eyelashes|eyepatch|medical eyepatch|blindfold|black blindfold'); " & ¬
        "front=re.compile(r'looking at viewer|eye contact|looking ahead|nose|dot nose|pointy nose|animal nose|nose blush|red nose|big nose|long nose'); " & ¬
        "blocked=re.compile(r'censored|mosaic censoring|bar censor|blur censor|identity censor|character censor|blank censor|pixelated|blurry|blurry foreground|motion blur|glitch|faceless(?: male| female)?|no eyes|covered face|covering face'); " & ¬
        "vals=lambda line:[clean(x.strip()) for x in line.split(',') if x.strip()]; " & ¬
        "special=lambda vs:any(eye.fullmatch(v) for v in vs) and any(front.fullmatch(v) for v in vs) and (not any(blocked.fullmatch(v) for v in vs) or 'uncensored' in vs); " & ¬
        "f=lambda line:(preset and special(vals(line))) or any(r.fullmatch(v) or r.fullmatch(v.replace(' ','_')) for v in vals(line) for r in rs); " & ¬
        "print('\\n'.join('1' if f(x) else '0' for x in o['tags']))"
    set resultText to do shell script "/usr/bin/python3 -c " & quoted form of py & " " & quoted form of payload
    return my splitLinesPreservingEmpty(resultText)
end regexMatchFlags

on validateRegexes(regexes)
    set payload to my jsonArrayOfStrings(regexes)
    set py to "import json,re,sys; [re.compile(x) for x in json.loads(sys.argv[1]) if x != '__EYES__']"
    try
        do shell script "/usr/bin/python3 -c " & quoted form of py & " " & quoted form of payload
    on error errMsg number errNum
        error "Invalid tag regular expression: " & errMsg number errNum
    end try
end validateRegexes

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

on mountRamdisk(sizeMB, volumeName)
    set sectors to sizeMB * 2048
    set cmd to "/usr/sbin/diskutil erasevolume HFS+ " & quoted form of volumeName & ¬
        " `/usr/bin/hdiutil attach -nomount ram://" & sectors & "` >/dev/null"
    do shell script cmd
end mountRamdisk

on unmountRamdisk(mountPath)
    try
        do shell script "/usr/sbin/diskutil eject " & quoted form of mountPath & " >/dev/null 2>&1 || true"
    end try
end unmountRamdisk

on prepareOutputDirectory(outputDir)
    do shell script "/bin/mkdir -p " & quoted form of outputDir
    set existing to do shell script "/usr/bin/find " & quoted form of outputDir & " -maxdepth 1 -type f -name 'frame_*.jpg' -print -quit"
    if existing is not "" then error "Output directory already contains generated frames: " & outputDir
end prepareOutputDirectory

on outputDirectoryFor(videoPath)
    set py to "from pathlib import Path; p=Path(__import__('sys').argv[1]); print(p.with_name(p.stem + '_frames'))"
    return do shell script "/usr/bin/python3 -c " & quoted form of py & " " & quoted form of videoPath
end outputDirectoryFor

on absoluteExistingFile(inputPath)
    set py to "from pathlib import Path; import sys; p=Path(sys.argv[1]).expanduser().resolve(); print(p if p.is_file() else '')"
    set resultPath to do shell script "/usr/bin/python3 -c " & quoted form of py & " " & quoted form of inputPath
    if resultPath is "" then error "Video file does not exist: " & inputPath
    return resultPath
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
    set py to "import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))"
    return do shell script "/usr/bin/python3 -c " & quoted form of py & " " & quoted form of (s as text)
end jsonQuote

on joinText(xs, delimiterText)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to delimiterText
    set resultText to xs as text
    set AppleScript's text item delimiters to oldDelimiters
    return resultText
end joinText

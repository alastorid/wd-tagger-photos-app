# wd-tagger-photos-app

Automatically tag photos in **Apple Photos.app** using **wd-tagger** and
a local GPU inference daemon.

This project connects **Apple Photos automation** with the popular
**wd-tagger image tagging model** to automatically generate keywords for
photos in your **Photos.app library**.

The tagging is performed locally using a fast **batch inference daemon
powered by PyTorch**, allowing large photo libraries to be processed
efficiently.

------------------------------------------------------------------------

## Features

-   Automatic **AI tagging for Apple Photos.app albums**
-   Uses **wd-tagger** for high-quality tag generation
-   **Local inference only** (no cloud services)
-   **GPU acceleration**
-   **Batch inference** for high throughput
-   **Async image preload cache**
-   Simple automation using **AppleScript**

------------------------------------------------------------------------

## How it works

1.  A local Python daemon runs **wd-tagger**
2.  The AppleScript reads images from a **Photos.app album**
3.  Images are sent to the daemon for **batch inference**
4.  Generated tags are written back as **Photos keywords**

This allows fully automated **AI tagging inside Apple Photos.app**.

------------------------------------------------------------------------

## Requirements

-   macOS
-   Apple **Photos.app**
-   Python **3.9+**
-   `git`
-   **Apple Silicon GPU**

------------------------------------------------------------------------

## Installation

Clone the repository:

``` bash
git clone https://github.com/alastorid/wd-tagger-photos-app.git
cd wd-tagger-photos-app
```

Start the tagging daemon:

``` bash
./wd_daemon/run.sh
```

This will:

-   create a Python virtual environment
-   install required dependencies
-   start the **wd-tagger inference daemon**

The daemon will run locally at:

    http://127.0.0.1:5566

------------------------------------------------------------------------

## Usage

Once the daemon is running, execute the AppleScript to tag a
**Photos.app album**.

``` bash
./tagger.applescript "album_name" "example_trigger_word"
```

Example:

``` bash
./tagger.applescript "album1" "smile"
```

This will:

-   read photos from album **album1**
-   generate tags using **wd-tagger**
-   write the tags back into **Photos keywords**
-   organize photos based on a trigger tag (e.g., `smile/album1` vs `no-smile/album1`).

### Extract video frames by tag

With the same daemon running, scan all frames in a video and retain only WD
tag matches:

``` bash
./extract_frame_by_tag.applescript video.mp4 'looks_at_viewer'
./extract_frame_by_tag.applescript video.mp4 'eyes.+' 'smile|grin'
./extract_frame_by_tag.applescript video.mp4 '__EYES__'
```

Each argument after the video is a Python regular expression matched against a
complete tag; multiple expressions are ORed. Both WD's space form
(`looks at viewer`) and underscore form (`looks_at_viewer`) are supported.
Matching JPEG frames are written as `frame_000000000001.jpg`, etc. in
`video_frames/`. FFmpeg is paused around each inference batch so decoded frames
remain bounded by a 512 MB RAM-disk buffer.

`__EYES__` is a built-in semantic preset for finding a face/eye region that is
not hidden by post-processing. It requires both an eye-related tag and
frontal-face/nose evidence such as `looking at viewer`, `looking ahead`, or
`nose`. Natural image content such as `closed eyes`, `hair over eyes`, an
`eyepatch`, or a `blindfold` is accepted. It rejects post-processing tags such
as `mosaic censoring`, `blur censor`, `pixelated`, `blurry`, `motion blur`, and
`glitch`, plus tags indicating that the face or eyes are absent. An explicit
`uncensored` tag overrides those rejection tags.

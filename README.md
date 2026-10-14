# Stenographer

Stenographer sits in the menu bar and writes down your meetings. You press Start, talk for an hour, press Stop, and the transcript is waiting in Apple Notes. Nothing leaves the Mac: the speech recognition is Apple's on-device model and the speaker separation runs locally too.

Most meeting transcribers want a bot in the call, an account somewhere, or both. This one wants a Mac and four permissions, and it speaks Greek and English.

## What it does

It listens to two sides at once. **Me** is your microphone, with echo cancellation so the call coming out of your speakers isn't counted as you. **Them** is everything the Mac plays (Teams, Zoom, a browser tab), captured straight from the audio system, so it works with any meeting app without joining the call.

Each side is diarized, which is a fancy way of saying it tells voices apart. When three people share a conference room mic or a call has five participants, the lines come out labelled `Me 1`, `Them 1`, `Them 2` and so on:

```
[00:00:04] Them 1: Καλημέρα, ξεκινάμε;
[00:00:07] Me 1: Ναι, πάμε.
```

The note is rewritten after every line, so if something crashes you lose the sentence in progress, not the meeting.

## Installing

Download `Stenographer.zip` from the [latest release](https://github.com/tsangiotis/stenographer/releases/latest), unzip it and drag `Stenographer.app` to Applications. It needs an Apple Silicon Mac with macOS 26 or later.

The app is signed but not notarized, so the first time you open it macOS will refuse and say it can't verify the developer. Go to **System Settings › Privacy & Security**, scroll down to the message about Stenographer and click **Open Anyway**. You only do this once.

On the first recording it asks for the microphone, system audio, speech recognition and permission to control Notes. Say yes to all four; without the system audio permission, it transcribes only your side. It may also spend a minute downloading the speech model for the language you picked.

## Using it

Click the waveform in the menu bar. **Start Recording** creates a note in a `Stenographer` folder in Notes, titled with the date and time, and fills it in as people talk. **Stop Recording** finishes the last lines and opens the note. Pick **Greek** or **English** before you start; the language is fixed for the whole recording.

It does one language per recording. If your meeting switches between Greek and English, everything is transcribed as the language you picked, with the results you would expect. Speaker labels are also numbered per side: `Them 2` means "the second voice heard from the call", not a name. Putting names on them is on you.

## Building from source

You need macOS 26 and Xcode 26. Then:

```sh
./build.sh
```

This builds a release binary, compiles the icon, signs the app and installs it to `/Applications`, quitting any running copy first. The script signs with my certificate, because a fixed identity keeps the microphone, audio and Notes permissions across rebuilds (an ad-hoc signature makes macOS ask again after every build). Change the `codesign -s` line to one of yours:

```sh
security find-identity -v -p codesigning
```

For testing, `--record 60` records for a minute and stops on its own, and `-language en_US` overrides the menu for one run:

```sh
/Applications/Stenographer.app/Contents/MacOS/Stenographer --record 60 -language en_US
```

If a side stays silent, watch the log. Each side reports its input level every five seconds, and a `peak` that never leaves zero means a missing permission:

```sh
log stream --predicate 'subsystem == "com.tsangiotis.stenographer"'
```

The icon is an [Icon Composer](https://developer.apple.com/icon-composer/) file, `AppIcon.icon`, and the build compiles it with `actool`. Speaker separation comes from [FluidAudio](https://github.com/FluidInference/FluidAudio)'s LS-EEND model.

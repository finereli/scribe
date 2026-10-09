<img src="logos/export/logo.svg" width="128" alt="Scribe icon">

# Scribe

**[Download Scribe for Mac](https://github.com/finereli/scribe/releases/latest/download/Scribe.dmg)** (free, 1 MB, macOS 14.2+) · [scribe.finereli.com](https://scribe.finereli.com)

A tiny Mac tool to transcribe your calls and paste them into Claude or ChatGPT. It listens to your Zoom, Meet or WhatsApp call from your side, so no bot joins, writes down who said what, and hands the transcript to your AI with one click. 2 MB, no dependencies, no account, free.

## Why I made this

A while ago I was on an important sales call. A few minutes in I realized we were on *their* Google Meet, not mine, which meant my note-taking bot was sitting in the waiting room. To get a transcript I'd have had to ask the buyer, in the middle of a pitch, to please let my robot in. I didn't. It felt like asking someone to let you record them while you're trying to get them to trust you.

So I had no transcript. Afterwards I tried to reconstruct what they'd told me, and I'd missed things that turned out to matter. I closed the deal, but barely.

That happened a few more times. I tried other tools. They were either bots, which have the same problem, or they ran big speech models that made my laptop work hard for an hour after every call. Then I noticed that my Mac was already pretty good at turning speech into text. It's been doing it for dictation for years, and it's built into the system. So I built the thing I actually wanted on top of that.

## Who it's for

People who spend their days on calls and don't like taking notes: founders, salespeople, coaches, managers. If you've ever finished a call and thought "wait, what was the number they said?", this is for you.

## What's different

**It's tiny.** Scribe isn't another place your meetings live. There's no account, no workspace and no AI of its own to learn. It's a 2 MB app with no dependencies that uses the speech recognizer already built into macOS, so there's no model to download. It runs on Apple Silicon and Intel Macs alike. Pick it up when a call starts, put it down when it ends.

**Your AI does the thinking.** Click the Claude or ChatGPT button and the transcript is copied with a line of context and the app opens. Paste, then ask what you actually want to know, in your own words.

**A backup for the calls that matter.** Keep using Fathom or Granola if you like them. Scribe sits next to them for the calls where the bot is stuck in the waiting room, the meeting is on someone else's account, or the call is too important to trust to one tool.

**There's no bot.** Nobody gets a "Notetaker wants to join" message. It doesn't matter whose meeting it is or which app it's in. Scribe listens on your Mac, the same way you do.

**Your audio stays on your Mac.** Both sides are saved as audio files on your disk, next to the transcript. There's no account and no server. (One caveat: English is transcribed entirely on your Mac. For other languages, macOS sends the audio to Apple's speech service, the same one dictation uses.)

**It knows who said what.** Your microphone is "Me" and whatever comes out of your Mac is "Them". For the usual one-on-one call, that's all the speaker detection you need, and it doesn't have to guess.

**It's free and open source.** MIT licensed, small enough to read before you trust it with your audio, and easy to change if you want it to do something it doesn't.

## Why now

Until recently the built-in transcription wasn't good enough to be worth keeping. Now it is, at least for what most of us actually do with transcripts: paste them into Claude or ChatGPT and ask "what did they agree to?", "what objections came up?", "write the follow-up email". An AI reading the transcript doesn't need every word to be perfect. It needs the conversation, and it needs it without you having to ask anyone's permission.

And the bots are being shown the door. In August 2026 Microsoft gave Teams admins a policy to detect and block notetaker bots. A tool that never joins the meeting doesn't have that problem.

## Next to what you already use

Scribe isn't trying to replace these. I pay for Fathom and MacWhisper, and both are good at what they do. I tried Granola too. Scribe is the small thing that works when they can't.

| | Scribe | Fathom | Granola | MacWhisper |
|---|---|---|---|---|
| How it hears the call | On your Mac | A bot joins the call | On your Mac | On your Mac |
| Works on someone else's meeting without asking | Yes | Only if they let the bot in | Yes | Yes |
| Where your audio goes | Stays on your Mac (English) | Their servers | Transcribed in their cloud | Stays on your Mac |
| Transcription engine | Built into macOS | Cloud | Cloud | Whisper models you download |
| Load on your Mac | Light | None | Light | Heavy, especially with the better models |
| Account needed | No | Yes | Yes | No |
| Summaries and analysis | Paste into your own AI | Built in | Built in | Some built in |
| Your old transcripts | Files on your disk, forever | In their app | Free plan: last 30 days | Files on your disk |
| Price | Free and open source | Free tier, paid plans | Free tier, paid from $14/month | Free version, paid Pro |

Fathom is great when you own the meeting and everyone expects a notetaker. Granola is great if you want AI-written notes and don't mind the cloud. MacWhisper is great for transcribing recordings as accurately as possible. Scribe is for when you just want the transcript, on your own Mac, without paying for it or making it anyone else's business.

## Install

1. [Download Scribe](https://github.com/finereli/scribe/releases/latest/download/Scribe.dmg) and drag it to Applications.
2. Open it. macOS will ask for three permissions: **Microphone** (your side), **Speech Recognition** (the transcript), and **System Audio Recording** (their side). Allow all three.

Requires macOS 14.2 (Sonoma) or later. Built for both Apple Silicon and Intel Macs.

## Use

1. Pick the call's language (English, Hebrew or Russian).
2. Press the red button (or ⌘R) when the call starts. Check that the **Me** and **Them** meters move.
3. Talk. The transcript appears as you go.
4. Press stop, then click the Claude or ChatGPT button and paste.

Every call is kept in its own folder (the folder icon opens it) with both sides recorded separately, so you can re-transcribe them later with anything you like.

## Made for real calls

- **Works with any headphones.** AirPods, Bluetooth buds or wired. Scribe records whatever your Mac is using.
- **Talking over each other is fine.** Each side is recorded as its own stream, so when a laggy connection has you both talking at once, every word from both of you still makes it into the transcript.
- **English, Hebrew and Russian.** Need another language? [Ask for it](https://github.com/finereli/scribe/issues/new?title=Language%20request%3A%20).

## Build from source

Scribe is a small SwiftPM app with no dependencies.

```sh
./build.sh          # local build
open Scribe.app
```

`SIGN=1 ./build.sh` signs it with a Developer ID, and `NOTARIZE=1 ./build.sh` also notarizes it.

## License

MIT

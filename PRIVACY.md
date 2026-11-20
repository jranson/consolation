# Consolation App - Privacy Policy

**Last updated:** November 16, 2026 (Consolation 2.0)

## Summary

Consolation does not collect, transmit, or share any personal data. Everything stays on your device.

The one exception you can reach is a YouTube link: it plays in YouTube's own embedded player, which connects to Google under Google's terms (see [YouTube links](#youtube-links)).

## Data Collection

**We collect nothing.** Consolation does not:

- Collect personal information
- Make network calls to anywhere you don't explicitly configure
- Use analytics, crash reporting services or tracking
- Communicate with any servers you don't add as a source or play as a URL

## What Consolation Reads

Consolation only reads its own settings, the video and audio from a capture card you connect, and the video and metadata from the sources you add.

## Capture Cards

Video and audio from a capture card stay on your device and are transient: Consolation never records, saves, streams or analyzes them. It uses the camera and microphone permissions only to show and play the capture card you choose.

## Network Connections

Consolation makes no network connections until you add a source or play a stream URL, and then it connects only to the tuners, servers and stream URLs you add or play. It searches your local network for tuners only when you ask. A YouTube link is the one exception: its player also connects to Google's hosts, listed below. If you use only a capture card, Consolation makes no network connections at all.

### Library servers (Bullpen)

When you add a Bullpen server, Consolation reads its catalog, library, channels and recordings (including the commercial breaks it found in a recording you play), and plays its streams, only from the address you added. "Find Servers on This Network" browses your local network for Bullpen servers (Bonjour) only when you choose it. A server's catalog can link artwork or media on other hosts; Consolation doesn't load artwork from any host but the server's own, so a card without it shows a generated picture instead. Consolation sends a server nothing about you beyond the requests themselves, and never writes to it. A bookmark to a YouTube video plays as described under [YouTube links](#youtube-links).

### YouTube links

On Mac, iPad and iPhone, a YouTube link you play in Quick Play, from Home's Quick Play History shelf, or from a Bullpen bookmark plays in YouTube's own embedded player (the YouTube IFrame Player API, through the open-source YouTubePlayerKit library). Consolation never downloads or extracts the video itself, and connects to YouTube only when you play a YouTube link.

While the player is open, it connects to Google, not to anything you added:

- `www.youtube.com` (the player and its script)
- YouTube's video servers (`*.googlevideo.com`) and image hosts (`i.ytimg.com`, `*.ggpht.com`)
- Google's script, font, ad and measurement hosts that YouTube's player loads (for example `www.gstatic.com`, `fonts.googleapis.com`, `googleads.g.doubleclick.net`, `static.doubleclick.net`, `www.google.com`)

What YouTube and Google collect there is governed by [Google's Privacy Policy](https://policies.google.com/privacy) and [YouTube's Terms of Service](https://www.youtube.com/t/terms), not by Consolation. To limit it, Consolation gives each video its own temporary website data that is never saved, so no YouTube cookies or storage outlive the player, and you aren't signed in to YouTube. Consolation gives YouTube only the video's ID, its start time and the app's identifier as the player's origin (YouTube requires embeds to identify themselves), and shows nothing over YouTube's player. Videos stop when you leave Now Playing; there is no background or audio-only playback. A YouTube link you click inside the player (the video's title, the YouTube logo, a channel) opens in your browser; other addresses the player tries to open are dropped.

On Apple TV, which can't show the embedded player, Consolation asks the YouTube app to open the video, if it's installed, and makes no connection itself.

### Plex Media Server

When you add a Plex server, Consolation connects only to the address you added, on your own network: it never contacts plex.tv, Plex's relays or any other Plex service, and it plays files directly rather than through Plex's transcoder. If you enter a Plex token, it is kept in your device's Keychain and sent only to that server, in a request header, never in a web address. Each request names the app and a random identifier made for this install, as Plex servers expect. "Find Plex Servers on This Network" browses your local network (Bonjour) only when you choose it. Consolation doesn't change anything on the server.

## Data Storage

Consolation stores its settings, including the sources and other settings you configure. No data leaves your device except for standard video transmission protocols that you initiate.

Quick Play history stays on your device and can be cleared in Settings. For a local file you chose, the history also keeps a bookmark, the system's permission for Consolation to open that file again; clearing the history removes it.

Where you stopped in videos that aren't live (for Home's Continue Watching) also stays on your device, never for live channels. Positions of Quick Play videos are kept only while Quick Play history is on, and clearing the history removes them. Home keeps a copy of its shelves in your device's caches so it can show them at once. It holds channel and video names and the names of the servers they come from, never full stream addresses or passwords. A Quick Play video's name is the last part of its address; Consolation shows the server's name instead when that part looks like a token, but it can't recognize every token, which is one reason the Quick Play History shelf is off by default.

## Changes

We may update this policy occasionally, but will never snoop on you or collect analytics. The "Last updated" date at the top reflects the latest version.

## Contact

Questions? Open an issue at [github.com/centennial-oss/consolation-apple/issues](https://github.com/centennial-oss/consolation-apple/issues).

For more info, see [centennialoss.org/privacy](https://centennialoss.org/privacy/).

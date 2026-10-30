# Consolation App - Privacy Policy

**Last updated:** October 25, 2026 (Consolation 2.0)

## Summary

Consolation does not collect, transmit, or share any personal data. Everything stays on your device.

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

Consolation makes no network connections until you add a source or play a stream URL, and then it connects only to the tuners, servers and stream URLs you add or play. It searches your local network for tuners only when you ask. If you use only a capture card, Consolation makes no network connections at all.

### Library servers (Bullpen)

When you add a Bullpen server, Consolation reads its catalog, library, channels and recordings, and plays its streams, only from the address you added. "Find Servers on This Network" browses your local network for Bullpen servers (Bonjour) only when you choose it. A server's catalog can link artwork or media on other hosts; Consolation doesn't load artwork from any host but the server's own, so a card without it shows a generated picture instead. Consolation sends a server nothing about you beyond the requests themselves, and never writes to it.

### Plex Media Server

When you add a Plex server, Consolation connects only to the address you added, on your own network: it never contacts plex.tv, Plex's relays or any other Plex service, and it plays files directly rather than through Plex's transcoder. If you enter a Plex token, it is kept in your device's Keychain and sent only to that server, in a request header, never in a web address. Each request names the app and a random identifier made for this install, as Plex servers expect. "Find Plex Servers on This Network" browses your local network (Bonjour) only when you choose it. Consolation doesn't change anything on the server.

## Data Storage

Consolation stores its settings, including the sources and other settings you configure. No data leaves your device except for standard video transmission protocols that you initiate.

Quick Play history stays on your device and can be cleared in Settings.

Where you stopped in videos that aren't live (for Home's Continue Watching) also stays on your device, never for live channels. Positions of Quick Play videos are kept only while Quick Play history is on, and clearing the history removes them. Home keeps a copy of its shelves in your device's caches so it can show them at once. It holds channel and video names and the names of the servers they come from, never full stream addresses or passwords. A Quick Play video's name is the last part of its address; Consolation shows the server's name instead when that part looks like a token, but it can't recognize every token, which is one reason the Quick Play History shelf is off by default.

## Changes

We may update this policy occasionally, but will never snoop on you or collect analytics. The "Last updated" date at the top reflects the latest version.

## Contact

Questions? Open an issue at [github.com/centennial-oss/consolation-apple/issues](https://github.com/centennial-oss/consolation-apple/issues).

For more info, see [centennialoss.org/privacy](https://centennialoss.org/privacy/).

---
name: watch-bbc
description: "Find a *currently-playable* BBC live stream URL and open it in VLC — HD channels (BBC One/Two/Four/News, 24/7) and UHD/4K event feeds (World Cup etc.). BBC DASH is clear (no DRM) so VLC plays it directly. The hard part is that a manifest returning HTTP 200 does NOT mean it plays — you must probe the live *segment* edge. Invoke when the user says 'watch BBC', 'play BBC One', 'BBC live stream', 'BBC iPlayer in VLC', 'is there a UHD/4K feed', 'World Cup in 4K', 'open BBC in VLC', '看 BBC', '播放 BBC', 'BBC 直播', 'BBC 4K/UHD'."
---

# Watch BBC live in VLC

Get a **playable** BBC live URL and open it in VLC. The whole skill exists because of one
trap: **a BBC manifest (`.mpd`) returning HTTP 200 does NOT mean the stream plays.** Event
feeds (UHD) stay reachable for ~25h after the broadcast ends, but their live edge 404s. You
must probe an actual media segment, never trust the manifest alone.

```
pick channel → verify live-segment edge (not just manifest) → open in VLC
```

## Why it works
- BBC DASH streams are **clear — no DRM/ContentProtection** → VLC plays them with zero setup.
  (ITV streams, by contrast, carry Widevine and will NOT play in VLC.)
- Video codec is **HEVC/H.265** (`hev1.*`) — VLC handles it natively.
- Many channels are **UK-geofenced**; `*-push-ww-live` ("worldwide", e.g. BBC News) works abroad,
  `*-push-uk-live` needs a UK IP. If a manifest 403s, that's geo — not a bug.

## Channel URLs

Source of truth, kept current: **[iptv-org/iptv `streams/uk_bbc.m3u`](https://github.com/iptv-org/iptv/blob/master/streams/uk_bbc.m3u)**
(`https://raw.githubusercontent.com/iptv-org/iptv/master/streams/uk_bbc.m3u`). Re-fetch it if a
URL below 404s — BBC rotates paths.

**24/7 HD channels** (always live; `availabilityStartTime` = epoch 1970):
| Channel | URL |
|---|---|
| BBC One London | `https://vs-cmaf-push-uk-live.akamaized.net/x=4/i=urn:bbc:pips:service:bbc_one_london/iptv_hd_abr_v1.mpd` |
| BBC Two HD | `https://vs-cmaf-push-uk-live.akamaized.net/x=4/i=urn:bbc:pips:service:bbc_two_hd/iptv_hd_abr_v1.mpd` |
| BBC Four HD | `https://vs-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_four_hd/iptv_hd_abr_v1.mpd` |
| BBC News (worldwide) | `https://vs-cmaf-push-ww-live.akamaized.net/x=4/i=urn:bbc:pips:service:bbc_news_channel_hd/iptv_hd_abr_v1.mpd` |

**UHD/4K** — there is **NO standing UHD channel.** UHD only exists *during a specific event*
(e.g. World Cup 2026), on slots `ve-uhd-push-uk-live.akamaized.net/.../uk_bbc_stream_0NN/iptv_uhd_v1.mpd`.
When the event ends the slot becomes a dead recording. Find the live one with the probe below.

## 1. Verify a stream is actually live

Manifest check alone is a lie — confirm the segment edge:

```bash
U="<manifest .mpd url>"
curl -s -A "Mozilla/5.0" -o /tmp/m.mpd -w "manifest HTTP %{http_code}\n" "$U"
grep -o "ContentProtection" /tmp/m.mpd && echo "!! DRM present — VLC can't play" || echo "clear, no DRM"
```

For HD channels (epoch AST) the edge is essentially always live; just open it. For **UHD /
event feeds, run the probe** — it computes the current segment number from
`availabilityStartTime` + `startNumber` and fetches it:

```bash
bash agent/skills/watch-bbc/probe-uhd.sh        # scans uk_bbc_stream_000..060, reports which are LIVE
bash agent/skills/watch-bbc/probe-uhd.sh 042    # check one specific slot's live edge
```
`<<< LIVE` = playable now. `404` at the edge = finished broadcast, do not open (VLC shows a
black screen). This is exactly the failure the user hits with a stale "working" link.

## 2. Open in VLC

```bash
pkill -x VLC 2>/dev/null; sleep 1        # only if replacing a dead stream
/Applications/VLC.app/Contents/MacOS/VLC "<url>" >/dev/null 2>&1 &
```
Run it backgrounded. If VLC opens but shows nothing, the live edge 404'd — re-probe; don't
blame VLC.

## World Cup 2026 (and any BBC/ITV-shared event) — the 4K gotcha

- **Only BBC matches are in 4K. ITV does not broadcast UHD at all.** If the user wants a match
  in 4K, first confirm the match is a **BBC** game — an ITV-exclusive match has *no* UHD feed
  anywhere, so probing UHD slots will (correctly) find nothing live.
- Check the broadcaster split before promising 4K. UK schedule + BBC/ITV split:
  [Sky Sports fixtures](https://www.skysports.com/football/news/11095/13481245/) ·
  [IBTimes BBC/ITV split](https://www.ibtimes.co.uk/bbc-itv-2026-world-cup-free-uk-1802243).
  Per-match channel: search `"<teamA>" "<teamB>" World Cup 2026 BBC or ITV`.
- A BBC UHD slot spins up ~around coverage start (often ~45 min before kickoff). If it's a BBC
  match and no slot is live yet, re-probe closer to kickoff, or use `/loop` to auto-poll and
  launch when `<<< LIVE` appears.
- For an ITV-only match there is no VLC-playable feed (DRM) — direct the user to **itvx.com** in
  a browser (free in the UK).

## Quick reference
- Manifest 200 ≠ playable. **Always probe the segment edge for event/UHD feeds.**
- No DRM on BBC → VLC just works. DRM on ITV → it won't.
- `-push-ww-` = worldwide, `-push-uk-` = UK-only (403 abroad).
- UHD = events only; ITV = never 4K.

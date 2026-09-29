#!/usr/bin/env bash
# probe-uhd.sh — find which BBC UHD event slot is actually LIVE right now.
#
# A BBC UHD manifest stays reachable (HTTP 200) for ~25h after a broadcast ends,
# but its live SEGMENT edge 404s once the event is over. This script computes the
# current segment number from the manifest's availabilityStartTime + startNumber
# and fetches it — the only reliable "is it playable" test.
#
# Usage:
#   probe-uhd.sh            # scan slots 000..060, print which are LIVE
#   probe-uhd.sh 042        # probe one specific slot
#   probe-uhd.sh 38 50      # scan an explicit numeric range
#
# A line ending in "<<< LIVE" is playable now; open its URL in VLC.

set -euo pipefail
UA="Mozilla/5.0"
HOST="https://ve-uhd-push-uk-live.akamaized.net"
svc() { printf "%s/x=4/i=urn:bbc:pips:service:uk_bbc_stream_%03d/iptv_uhd_v1.mpd" "$HOST" "$1"; }
base() { printf "%s/x=4/i=urn:bbc:pips:service:uk_bbc_stream_%03d/" "$HOST" "$1"; }

probe_one() {  # $1 = numeric slot id
  local n="$1" id mpd url ast sn pub asts now live code b
  id=$(printf "%03d" "$n"); url=$(svc "$n"); mpd=/tmp/uhd_${id}.mpd
  code=$(curl -s -m 8 -A "$UA" -o "$mpd" -w "%{http_code}" "$url" || echo 000)
  [ "$code" != "200" ] && { [ -n "${VERBOSE:-}" ] && echo "stream_$id: manifest HTTP $code"; return 0; }
  grep -q "<MPD" "$mpd" || return 0
  ast=$(grep -oE 'availabilityStartTime="[^"]*"' "$mpd" | head -1 | sed 's/.*="//;s/\..*//;s/"//')
  sn=$(grep -oE 'startNumber="[0-9]*"' "$mpd" | head -1 | sed 's/.*="//;s/"//')
  pub=$(grep -oE 'publishTime="[^"]*"' "$mpd" | head -1 | sed 's/.*="//;s/\..*//;s/"//')
  asts=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$ast" +%s 2>/dev/null || echo 0)
  now=$(date -u +%s)
  # UHD video segment: timescale=200, duration=768 -> 3.84s/segment
  live=$(( sn + (now - asts) * 200 / 768 ))
  b=$(base "$n")
  code=$(curl -s -m 8 -A "$UA" -o /dev/null -w "%{http_code}" "${b}t=3840/v=pv76/b=2000000/${live}.m4s" || echo 000)
  printf "stream_%s  pub=%s  edge#%d -> HTTP %s%s\n" \
    "$id" "$pub" "$live" "$code" "$([ "$code" = 200 ] && echo "   <<< LIVE  $url")"
}

echo "now: $(date -u)  ($(TZ=Europe/London date '+%H:%M %Z' 2>/dev/null))"
if [ "$#" -eq 1 ]; then
  probe_one "$((10#$1))"
elif [ "$#" -eq 2 ]; then
  for n in $(seq "$((10#$1))" "$((10#$2))"); do probe_one "$n"; done
else
  for n in $(seq 0 60); do probe_one "$n"; done
fi

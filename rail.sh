#!/usr/bin/env bash

# ============================================================
# BANGLADESH RAILWAY SEAT MONITOR
# TERMUX / ANDROID + generic Linux terminal
# ============================================================

set -u
set +H 2>/dev/null || true

CONFIG="$HOME/railway-monitor.json"

MIN_INTERVAL=8
DEFAULT_INTERVAL=10

# ============================================================
# PAGER TONE (same repo: stations.txt + pager.wav live next
# to this script on GitHub, fetched as raw files when needed)
# ============================================================

PAGER_FILE="$HOME/pager.wav"
PAGER_URL="https://raw.githubusercontent.com/lutfor183/rail-reckon/main/pager.wav"
PAGER_MIN_BYTES=20000 # a real wav is ~300KB; anything smaller is an error page

# ============================================================
# COLORS
# ============================================================

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
C='\033[0;36m'
W='\033[1;37m'
D='\033[0;90m'
N='\033[0m'

# ============================================================
# GLOBALS
# ============================================================

URL=""
FROM=""
TO=""
DATE=""
SEAT_CLASS=""
INTERVAL="$DEFAULT_INTERVAL"
MODE=""
FREE_BASE="https://cybershbd.xyz/BdRail/index.php"

declare -a WANTED_TRAINS=()
declare -a WANTED_CLASSES=()

declare -a TRAIN_JSON=()
declare -a CLASS_NAMES=()
declare -a CURL_HEADERS=()

is_termux() {
    [[ -n "${PREFIX:-}" && "$PREFIX" == *"com.termux"* ]] || [[ -d "/data/data/com.termux" ]]
}

ensure_deps() {
    local missing=()
    local cmd
    for cmd in curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        echo -e "${Y}Installing missing dependencies: ${missing[*]}${N}"
        if is_termux; then
            if command -v pkg >/dev/null 2>&1; then
                pkg update -y >/dev/null 2>&1 || true
                pkg install -y "${missing[@]}" >/dev/null 2>&1 || {
                    echo -e "${R}pkg install failed.${N}"
                    return 1
                }
            else
                echo -e "${R}pkg not found.${N}"
                return 1
            fi
        elif command -v apt-get >/dev/null 2>&1; then
            if command -v sudo >/dev/null 2>&1 && [[ "$(id -u)" -ne 0 ]]; then
                sudo apt-get update >/dev/null 2>&1 || true
                sudo apt-get install -y "${missing[@]}" >/dev/null 2>&1 || return 1
            else
                apt-get update >/dev/null 2>&1 || true
                apt-get install -y "${missing[@]}" >/dev/null 2>&1 || return 1
            fi
        else
            echo -e "${R}Missing: ${missing[*]}. Please install them manually.${N}"
            return 1
        fi
        for cmd in "${missing[@]}"; do
            command -v "$cmd" >/dev/null 2>&1 || {
                echo -e "${R}Could not install $cmd.${N}"
                return 1
            }
        done
        echo -e "${G}Deps ready.${N}"
    fi
    # Termux:API bridge (vibration/alerts). Installed on demand when
    # missing — the monitor still runs without it, just quieter.
    if is_termux; then
        if ! command -v termux-notification >/dev/null 2>&1 || \
           ! command -v termux-vibrate >/dev/null 2>&1; then
            if command -v pkg >/dev/null 2>&1; then
                pkg install -y termux-api >/dev/null 2>&1 || true
            fi
            if ! command -v termux-notification >/dev/null 2>&1; then
                echo -e "${Y}Termux:API unavailable — install the Termux:API app + 'pkg install termux-api' for vibration/alerts.${N}"
            fi
        fi
    fi
    return 0
}

# ============================================================
# NORMALIZE
# ============================================================

norm() {
    printf '%s' "$1" |
        tr '[:upper:]' '[:lower:]' |
        tr -d "'" |
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ============================================================
# STATIONS — loaded from stations.txt in this same GitHub repo
# (one name per line), cached at $HOME/.rail_stations.txt and
# refreshed daily. Nothing hardcoded, no code bloat.
# ============================================================

STATIONS_URL="https://raw.githubusercontent.com/lutfor183/rail-reckon/main/stations.txt"
STATIONS_CACHE="$HOME/.rail_stations.txt"
STATIONS_MAX_AGE=86400 # seconds (1 day)

# Offline fallback: major stations only, used when neither the
# cache nor GitHub is reachable.
CORE_STATIONS=(Dhaka Chattogram Khulna Rajshahi Sylhet Rangpur Mymensingh Jashore Dinajpur)

STATIONS=()
STATION_NORM=()
STATION_COMPACT=()

# Match keys, computed ONCE per load (not per keystroke) — this is
# what keeps the picker instant even on slow phones.
build_station_keys() {
    STATION_NORM=()
    STATION_COMPACT=()
    local s
    for s in "${STATIONS[@]}"; do
        STATION_NORM+=("$(norm "$(strip_possessive "$s")")")
        STATION_COMPACT+=("$(norm_compact "$(strip_possessive "$s")")")
    done
}

load_stations() {
    STATIONS=()
    local src="" line tmp mtime
    local now age
    now="$(date +%s 2>/dev/null || echo 0)"
    age=999999999
    if [[ -s "$STATIONS_CACHE" ]]; then
        mtime="$(stat -c%Y "$STATIONS_CACHE" 2>/dev/null || stat -f%m "$STATIONS_CACHE" 2>/dev/null || echo 0)"
        [[ "$mtime" =~ ^[0-9]+$ ]] && [[ "$now" =~ ^[0-9]+$ ]] && age=$((now - mtime))
    fi
    if [[ -s "$STATIONS_CACHE" ]] && (( age < STATIONS_MAX_AGE )); then
        src="$STATIONS_CACHE"
    else
        tmp="$(mktemp)"
        if { command -v curl >/dev/null 2>&1 && curl --silent --location --fail --retry 1 --connect-timeout 10 --max-time 30 "$STATIONS_URL" -o "$tmp" 2>/dev/null; } || \
           { command -v wget >/dev/null 2>&1 && wget --quiet --tries=1 --timeout=30 -O "$tmp" "$STATIONS_URL" 2>/dev/null; }; then
            if [[ -s "$tmp" ]] && (( $(wc -l < "$tmp" 2>/dev/null || echo 0) >= 100 )); then
                mv "$tmp" "$STATIONS_CACHE"
                chmod 600 "$STATIONS_CACHE" 2>/dev/null || true
                src="$STATIONS_CACHE"
            else
                rm -f "$tmp"
            fi
        else
            rm -f "$tmp"
        fi
        if [[ -z "$src" ]]; then
            if [[ -s "$STATIONS_CACHE" ]]; then
                src="$STATIONS_CACHE"
            else
                STATIONS=("${CORE_STATIONS[@]}")
                build_station_keys
                return 0
            fi
        fi
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$line" ]] && STATIONS+=("$line")
    done < "$src"
    (( ${#STATIONS[@]} > 0 )) || STATIONS=("${CORE_STATIONS[@]}")
    build_station_keys
}

# 1 when /dev/tty can actually be opened (a real terminal is
# attached); 0 when piped/backgrounded. Probed once at startup —
# [[ -r /dev/tty ]] alone is not enough: the node can exist yet
# refuse to open ("No such device or address"), which used to
# spam errors and break every prompt.
HAVE_TTY=0
if { true < /dev/tty; } 2>/dev/null; then
    HAVE_TTY=1
fi

# ============================================================
# ASK — every question is printed where the user can always see
# it (terminal, or stderr when there is no /dev/tty), and EOF
# returns 1 instead of hanging in an endless loop.
# ============================================================

# ask PROMPT VAR — print PROMPT, read one line into VAR.
ask() {
    local prompt="$1" var="$2" val="" rc=0
    if [[ -z "${ASK_NO_TTY:-}" ]] && (( HAVE_TTY == 1 )); then
        printf '%s' "$prompt" > /dev/tty
    else
        printf '%s' "$prompt" >&2
    fi
    if [[ -z "${ASK_NO_TTY:-}" ]] && (( HAVE_TTY == 1 )); then
        IFS= read -r val < /dev/tty || rc=1
    else
        IFS= read -r val || rc=1
    fi
    printf -v "$var" '%s' "$val"
    return $rc
}

# ask_key TIMEOUT VAR — single keypress within TIMEOUT seconds.
# Returns 1 on timeout/EOF. Never prints errors.
ask_key() {
    local timeout="$1" var="$2" val=""
    (( HAVE_TTY == 1 )) || return 1
    IFS= read -r -t "$timeout" -n 1 val < /dev/tty 2>/dev/null || { printf -v "$var" '%s' ""; return 1; }
    printf -v "$var" '%s' "$val"
    return 0
}

# Compact form: lowercase, no spaces/underscores/hyphens/apostrophes.
# Catches "cox bazar", "Cox-Bazar", "bimanbandar" style input.
norm_compact() {
    norm "$1" | tr -d ' _-'
}

# "Cox's Bazar" -> "Cox Bazar", so typing "cox bazar" (the
# natural input, without apostrophe) still matches.
strip_possessive() {
    printf '%s' "$1" | sed "s/'[sS]//g"
}

# All stations containing the query (case-insensitive; spaces,
# underscores, hyphens and apostrophes ignored), one per line.
station_matches() {
    local ql qlc i
    (( ${#STATION_NORM[@]} == ${#STATIONS[@]} )) || build_station_keys
    ql="$(norm "$(strip_possessive "$1")")"
    qlc="$(norm_compact "$(strip_possessive "$1")")"
    [[ -z "$ql" ]] && return 1
    for ((i=0; i<${#STATIONS[@]}; i++)); do
        if [[ "${STATION_NORM[$i]}" == *"$ql"* ]]; then
            printf '%s\n' "${STATIONS[$i]}"
        elif [[ "${STATION_COMPACT[$i]}" == *"$qlc"* ]]; then
            printf '%s\n' "${STATIONS[$i]}"
        fi
    done
}

# Interactive station picker: type any part of the name, then pick
# a number from the options. Never auto-selects — even a single
# hit is shown as option 1 to confirm (unless it is the saved
# value, kept via [keep: ...]). Always returns canonical spelling.
pick_station() {
    local prompt="$1" current="$2"
    local q="" i n
    local -a matches=()
    (( ${#STATIONS[@]} > 0 )) || load_stations
    if [[ -n "$current" ]]; then
        ask "$prompt [keep: $current]: " q || return 1
        [[ -z "$q" ]] && { printf '%s' "$current"; return 0; }
    else
        ask "$prompt (type part of the station name): " q || return 1
    fi
    while true; do
        if [[ -z "$q" ]]; then
            if [[ -n "$current" ]]; then
                printf '%s' "$current"
                return 0
            fi
            ask "Type part of a station name: " q || return 1
            continue
        fi
        if [[ "$q" =~ ^[0-9]+$ ]] && (( ${#matches[@]} > 0 )) && (( q >= 1 && q <= ${#matches[@]} )); then
            printf '%s' "${matches[$((q-1))]}"
            return 0
        fi
        matches=()
        while IFS= read -r s; do
            [[ -n "$s" ]] && matches+=("$s")
        done < <(station_matches "$q")
        n="${#matches[@]}"
        if (( n == 0 )); then
            echo -e "${R}No station matches '$q'. Try again (e.g. 'dha' for Dhaka).${N}" >&2
            ask "Station: " q || return 1
            continue
        fi
        if (( n > 20 )); then
            echo -e "${Y}${n} stations match '$q' — too many, type more letters.${N}" >&2
            matches=()
            ask "Narrow it down: " q || return 1
            continue
        fi
        if (( n == 1 )); then
            echo -e "${Y}1 station matches:${N}" >&2
        else
            echo -e "${Y}${n} stations match — pick a number:${N}" >&2
        fi
        for ((i=0; i<n; i++)); do
            echo -e "  ${C}$((i+1)))${N} ${matches[i]}" >&2
        done
        ask "Pick 1-$n (or type more letters): " q || return 1
    done
}

# ============================================================
# DATE NORMALIZE
#
# The Railway site expects "DD-Mon-YYYY" (e.g. 09-Sep-2026),
# but nobody wants to type it that way by hand. This accepts
# pretty much any reasonable format and converts it:
#
#   22-04-26      -> 22-Apr-2026
#   22-04-2026    -> 22-Apr-2026
#   2026-04-22    -> 22-Apr-2026
#   22/4/26       -> 22-Apr-2026
#   22.4.2026     -> 22-Apr-2026
#   22-Apr-26     -> 22-Apr-2026
#   Apr-22-2026   -> 22-Apr-2026
#
# Returns 1 (and prints nothing) if the input can't be parsed,
# so the caller can re-prompt instead of saving garbage.
# ============================================================

MONTH_NAMES=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

month_to_num() {
    local mon
    mon="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$mon" in
        jan*) echo 1 ;;  feb*) echo 2 ;;  mar*) echo 3 ;;
        apr*) echo 4 ;;  may*) echo 5 ;;  jun*) echo 6 ;;
        jul*) echo 7 ;;  aug*) echo 8 ;;  sep*) echo 9 ;;
        oct*) echo 10 ;; nov*) echo 11 ;; dec*) echo 12 ;;
        *) echo "" ;;
    esac
}

normalize_date() {

    local raw
    raw="$(norm "$1")"

    # Unify every separator (space, /, ., _) to '-', then
    # collapse repeats.
    local cleaned
    cleaned="$(
        printf '%s' "$raw" |
            tr ' /._' '----' |
            sed 's/-\+/-/g'
    )"

    local d="" m="" y="" mon=""

    if [[ "$cleaned" =~ ^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})$ ]]; then
        # YYYY-MM-DD
        y="${BASH_REMATCH[1]}"
        m="${BASH_REMATCH[2]}"
        d="${BASH_REMATCH[3]}"

    elif [[ "$cleaned" =~ ^([0-9]{1,2})-([0-9]{1,2})-([0-9]{2}|[0-9]{4})$ ]]; then
        # DD-MM-YY or DD-MM-YYYY
        d="${BASH_REMATCH[1]}"
        m="${BASH_REMATCH[2]}"
        y="${BASH_REMATCH[3]}"

    elif [[ "$cleaned" =~ ^([0-9]{1,2})-([a-zA-Z]{3,9})-([0-9]{2}|[0-9]{4})$ ]]; then
        # DD-Mon-YY or DD-Mon-YYYY
        d="${BASH_REMATCH[1]}"
        mon="${BASH_REMATCH[2]}"
        y="${BASH_REMATCH[3]}"
        m="$(month_to_num "$mon")"

    elif [[ "$cleaned" =~ ^([a-zA-Z]{3,9})-([0-9]{1,2})-([0-9]{2}|[0-9]{4})$ ]]; then
        # Mon-DD-YYYY (US style)
        mon="${BASH_REMATCH[1]}"
        d="${BASH_REMATCH[2]}"
        y="${BASH_REMATCH[3]}"
        m="$(month_to_num "$mon")"

    else
        return 1
    fi

    [[ -z "$m" || -z "$d" || -z "$y" ]] && return 1

    # 2-digit year -> 20YY (this API is never booking for 19xx)
    (( ${#y} == 2 )) && y="20${y}"

    d=$((10#$d))
    m=$((10#$m))
    y=$((10#$y))

    (( m >= 1 && m <= 12 )) || return 1
    (( d >= 1 && d <= 31 )) || return 1

    printf '%02d-%s-%04d' "$d" "${MONTH_NAMES[$((m-1))]}" "$y"
}

# ============================================================
# ASK DATE — prompts, normalizes, and loops on invalid input
# instead of silently saving something the API will reject.
# $1 = prompt text, $2 = current value (empty ok)
# Prints the normalized date, or nothing + returns 1 on abort
# (empty input on a prompt with no current value).
# ============================================================

ask_date() {

    local prompt="$1"
    local current="$2"
    local v result

    while true; do

        ask "$prompt" v || return 1

        if [[ -z "$v" ]]; then
            [[ -n "$current" ]] && { printf '%s' "$current"; return 0; }
            return 1
        fi

        if result="$(normalize_date "$v")"; then
            printf '%s' "$result"
            return 0
        fi

        echo -e "${R}Couldn't understand that date. Try formats like 22-04-26, 2026-04-22, or 22-Apr-2026.${N}"
    done
}

# ============================================================
# TRAIN NAME / TRAIN ID
#
# CONFIRMED BUG (from --dump on live data):
# this API's field *names* lie about what they hold. On the
# live response, .train_model held the bare trip number
# ("826") while .trip_number held the full descriptive string
# ("JAHANABAD EXPRESS (826)") — backwards from what those key
# names suggest. Picking fields by name alone silently swapped
# the train's name and ID, which broke every downstream
# comparison (saved selections stopped matching -> seats were
# detected but reported as "no seats available").
#
# FIX: don't trust field names — detect by content instead.
# Whichever candidate field is text containing letters is the
# display name; whichever is pure digits is the ID. This is
# correct regardless of which literal key the API happens to
# stash each value under, and survives future field renames.
# ============================================================

train_name() {
    jq -r '
        if type == "object" then
            (
                [
                    .train_name, .trip_number, .train_model, .name,
                    .trip_name, .title, .trip_title
                ]
                | map(select(. != null) | tostring)
                | map(select(test("[A-Za-z]")))
                | first
            ) // ""
        else
            ""
        end
    ' <<< "$1" 2>/dev/null
}

train_id() {
    jq -r '
        if type == "object" then
            (
                [
                    .trip_number, .train_model, .train_id, .trip_id,
                    .train_code, .trip_code, .train_number, .number,
                    .code, .trip_title
                ]
                | map(select(. != null) | tostring)
                | map(select(test("^[0-9]+$")))
                | first
            ) // ""
        else
            ""
        end
    ' <<< "$1" 2>/dev/null
}

# ============================================================
# BASE NAME — strips a trailing " (123)" trip-number suffix,
# so a saved selection still matches the same physical train
# even if its trip number has changed (this API assigns
# different trip numbers to the same named train depending on
# day of week / direction — e.g. JAHANABAD EXPRESS as 825 one
# day and 826 the next).
# ============================================================

base_name() {
    printf '%s' "$1" | sed -E 's/[[:space:]]*\([0-9]+\)[[:space:]]*$//'
}

# ============================================================
# CLASS NAME
# ============================================================

class_name() {
    jq -r '
        if type == "object" then
            (
                .type //
                .seat_class //
                .seat_type //
                .name //
                .class //
                .class_name //
                ""
            )
        else
            ""
        end
        | tostring
    ' <<< "$1" 2>/dev/null
}

# ============================================================
# SEAT COUNT
#
# The Railway/Shohoz API is not publicly documented and its
# shape has been observed to vary between endpoints. Some
# responses expose a flat number (available_seats / seats /
# available). Others — including this same API family's
# fare-matrix responses — expose a nested object:
#
#   "seat_counts": { "online": 1, "offline": 0 }
#
# "online" is the web-bookable count (what the "BOOK NOW"
# button reflects). We check the flat fields first, then the
# nested seat_counts fields, then fall back to summing any
# numeric leaves inside seat_counts as a last resort.
#
# If seats still don't get detected, run this script with
# --dump to inspect the real field names in your live
# response and adjust the field list above accordingly.
# ============================================================

seat_count() {
    jq -r '
        if type == "object" then
            (
                .available_seats //
                .seats //
                .available //
                .seat_counts.online //
                .seat_counts.available //
                .online //
                .count //
                (
                    if (.seat_counts | type) == "object"
                    then ([.seat_counts[] | numbers] | add)
                    else empty
                    end
                ) //
                0
            )
            | tonumber?
            // 0
            | floor

        elif type == "number" then
            floor

        elif type == "string" then
            tonumber?
            // 0
            | floor

        else
            0
        end
    ' <<< "$1" 2>/dev/null
}

# ============================================================
# ENSURE PAGER TONE — download once, cache locally. Safe to
# call every round; it's a no-op once the file exists.
# ============================================================

ensure_pager_tone() {
    if [[ -s "$PAGER_FILE" ]] && (( $(stat -c%s "$PAGER_FILE" 2>/dev/null || stat -f%z "$PAGER_FILE" 2>/dev/null || echo 0) >= PAGER_MIN_BYTES )); then
        return 0
    fi
    # Stale/partial file (e.g. an HTML error page) — drop it and refetch.
    rm -f "$PAGER_FILE" "$PAGER_FILE.tmp"
    [[ -z "${PAGER_URL:-}" ]] && return 1
    local ok=1
    if command -v curl >/dev/null 2>&1; then
        curl --silent --location --fail --retry 2 --connect-timeout 10 --max-time 60 \
            "$PAGER_URL" -o "$PAGER_FILE.tmp" 2>/dev/null || ok=0
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --tries=2 --timeout=60 -O "$PAGER_FILE.tmp" "$PAGER_URL" 2>/dev/null || ok=0
    else
        return 1
    fi
    if (( ok == 1 )) && [[ -s "$PAGER_FILE.tmp" ]]; then
        mv "$PAGER_FILE.tmp" "$PAGER_FILE"
        local bytes
        bytes=$(stat -c%s "$PAGER_FILE" 2>/dev/null || stat -f%z "$PAGER_FILE" 2>/dev/null || echo 0)
        (( bytes >= PAGER_MIN_BYTES )) && return 0
        rm -f "$PAGER_FILE"
    fi
    rm -f "$PAGER_FILE.tmp"
    return 1
}

play_tone_once() {
    [[ -s "$PAGER_FILE" ]] || return 1
    if command -v termux-media-player >/dev/null 2>&1; then
        termux-media-player play "$PAGER_FILE" >/dev/null 2>&1 &
        echo $!
        return 0
    elif command -v mpv >/dev/null 2>&1; then
        mpv --no-video --really-quiet "$PAGER_FILE" >/dev/null 2>&1 &
        echo $!
        return 0
    elif command -v ffplay >/dev/null 2>&1; then
        ffplay -nodisp -autoexit -loglevel quiet "$PAGER_FILE" >/dev/null 2>&1 &
        echo $!
        return 0
    elif command -v paplay >/dev/null 2>&1; then
        paplay "$PAGER_FILE" >/dev/null 2>&1 &
        echo $!
        return 0
    elif command -v aplay >/dev/null 2>&1; then
        aplay -q "$PAGER_FILE" >/dev/null 2>&1 &
        echo $!
        return 0
    fi
    return 1
}

stop_tone_pid() {
    local pid="${1:-}"
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
    if command -v termux-media-player >/dev/null 2>&1; then
        termux-media-player stop >/dev/null 2>&1 || true
    fi
}

# ============================================================
# RING — loud alert via termux-notification, 3 rounds, ~60s each
#
# Press ANY key to stop the alarm immediately.
# Press 'e' specifically to stop it AND jump straight into the
# edit menu (useful the moment a seat alert fires, since you
# can't wait for the countdown to press 'e' at that point).
#
# Requires: pkg install termux-api  (+ Termux:API app installed
# with permissions granted).
#
# WHY THIS DESIGN:
# - termux-media-player needs a real file path; content:// URIs
#   and /system/media paths are not reliably readable without
#   root, so it can silently fail to play anything.
# - termux-vibrate -d 60000 run once in the background cannot
#   be reliably cancelled early on many Android builds — the
#   "override" call doesn't always pre-empt it, which is why
#   vibration kept running after a keypress.
# - A raw 25-second uninterruptible termux-media-player loop
#   (the naive approach) can't be stopped instantly — you'd be
#   stuck hearing it out even after pressing a key. Instead we
#   fire everything (tone + vibrate) in short (~1s-2s) repeating
#   bursts, alongside a termux-notification for the vibrate
#   pattern (which is the one primitive that reliably survives
#   the screen being locked, without root). There is nothing
#   long-running to cancel — breaking the loop on keypress and
#   issuing one "stop" is enough to silence everything almost
#   instantly, whether or not a custom pager.wav is configured.
# ============================================================

ring_alarm() {

    local have_tone=0
    ensure_pager_tone && have_tone=1

    local rounds=3
    local total_seconds=15
    local step=1
    local replay_every=2
    local stopped=0
    local key=""
    local notif_id=99110
    local tone_pid=""
    local elapsed=0
    local since_replay=99

    echo -e "${Y}Press any key to stop. Press 'e' to stop AND edit search.${N}"

    if ! command -v termux-notification >/dev/null 2>&1 &&
       ! command -v termux-vibrate >/dev/null 2>&1; then
        echo -e "${R}termux-api commands not found — no sound/vibration is possible.${N}"
        echo -e "${D}Run: pkg install termux-api  (and install the Termux:API app from F-Droid/Play)${N}"
    fi

    for ((r=1; r<=rounds; r++)); do

        (( stopped == 1 )) && break

        echo -e "${R}RINGING (${r}/${rounds}, ${total_seconds}s)...${N}"

        if command -v termux-notification >/dev/null 2>&1; then
            termux-notification --id "$notif_id" --title "Seat Available - BOOK NOW" --content "$FROM to $TO - tap to open Termux" --priority max --sound --vibrate 0,700,300,700 >/dev/null 2>&1 || true
        elif command -v notify-send >/dev/null 2>&1; then
            notify-send "Seat Available - BOOK NOW" "$FROM to $TO" >/dev/null 2>&1 || true
        fi

        elapsed=0
        since_replay=99

        while (( elapsed < total_seconds )); do

            if (( have_tone == 1 )) && (( since_replay >= replay_every )); then
                stop_tone_pid "$tone_pid" 2>/dev/null || true
                tone_pid="$(play_tone_once 2>/dev/null || true)"
                since_replay=0
            fi

            if command -v termux-vibrate >/dev/null 2>&1; then
                termux-vibrate -d 700 -f >/dev/null 2>&1 || true
            fi

            if ! command -v termux-notification >/dev/null 2>&1 &&
               ! command -v termux-vibrate >/dev/null 2>&1; then
                printf '\a'
            fi

            if ask_key "$step" key; then
                stopped=1
                break
            elif (( HAVE_TTY == 0 )); then
                sleep "$step"
            fi

            elapsed=$((elapsed + step))
            since_replay=$((since_replay + step))

        done

        stop_tone_pid "$tone_pid" 2>/dev/null || true
        tone_pid=""
        if command -v termux-notification-remove >/dev/null 2>&1; then
            termux-notification-remove "$notif_id" >/dev/null 2>&1 || true
        fi

        (( stopped == 1 )) && break

        (( r < rounds )) && sleep 5

    done

    if (( stopped == 1 )); then

        echo -e "${G}✓ Alarm stopped.${N}"

        if [[ "$key" == "e" || "$key" == "E" ]]; then
            edit_menu
            return
        fi

    fi

    echo -e "${C}Press 'e' within 10s to edit search now, or wait to keep monitoring...${N}"

    if ask_key 10 key; then
        [[ "$key" == "e" || "$key" == "E" ]] && edit_menu || true
    else
        sleep 2 || true
    fi
}

# ============================================================
# OPEN BOOKING PAGE — launches Firefox directly (assumes the
# Railway account is already logged in inside Firefox).
#
# NOTE: the query-string param names below (fromcity/tocity/
# doj/class) are a best guess since the site is a JS SPA.
# Do one manual search in Firefox, check the address bar for
# the real parameter names, and adjust the url= line to match.
# ============================================================

open_booking_page() {

    local url="https://eticket.railway.gov.bd/booking/train/search?fromcity=${FROM}&tocity=${TO}&doj=${DATE}&class=${SEAT_CLASS}"

    if command -v am >/dev/null 2>&1; then
        am start -a android.intent.action.VIEW -d "$url" org.mozilla.firefox >/dev/null 2>&1
    elif command -v termux-open-url >/dev/null 2>&1; then
        termux-open-url "$url"
    fi
}

# ============================================================
# SET URL PARAM — replace/append a single query-string
# parameter on $URL (used by the edit menu)
# ============================================================

set_url_param() {
    local key="$1"
    local value="$2"
    local url="$URL"
    local encoded
    encoded="$(printf '%s' "$value" | jq -sRr @uri)"

    local pattern="[?&]${key}="
    if [[ "$url" =~ $pattern ]]; then
        esc="$(printf '%s' "$encoded" | sed -e 's/[\\&|]/\\&/g')"
        URL="$(printf '%s' "$url" | sed -E "s|([?&]${key}=)[^&]*|\1${esc}|")"
    elif [[ "$url" == *"?"* ]]; then
        URL="${url}&${key}=${encoded}"
    else
        URL="${url}?${key}=${encoded}"
    fi
    if [[ "${MODE:-}" == "free" ]]; then
        build_free_url
    fi
}

# ============================================================
# CONFIRM SEARCH PARAMETERS — shown at every startup, before
# any API call, so the date/route/class can be corrected right
# away instead of only being editable mid-run.
# ============================================================

confirm_search_params() {

    # No saved data yet: ask for each missing field directly
    # instead of showing blanks behind a yes/no gate.
    if [[ -z "$FROM" || -z "$TO" || -z "$DATE" || -z "$SEAT_CLASS" ]]; then
        echo
        echo -e "${W}Enter search details:${N}"
        if [[ -z "$DATE" ]]; then
            DATE="$(ask_date "Date of journey (e.g. 22-04-26 or 22-Apr-2026): " "")" || exit 1
            set_url_param "date_of_journey" "$DATE"
        fi
        if [[ -z "$FROM" ]]; then
            FROM="$(pick_station "From city" "")" || exit 1
            set_url_param "from_city" "$FROM"
        fi
        if [[ -z "$TO" ]]; then
            TO="$(pick_station "To city" "")" || exit 1
            set_url_param "to_city" "$TO"
        fi
        if [[ -z "$SEAT_CLASS" ]]; then
            ask "Seat class (type a name like S_CHAIR, or ALL): " SEAT_CLASS || exit 1
            SEAT_CLASS="$(printf '%s' "$SEAT_CLASS" | tr '[:lower:]' '[:upper:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -z "$SEAT_CLASS" ]] && SEAT_CLASS="ALL"
            set_url_param "seat_class" "$SEAT_CLASS"
        fi
        save_config
        echo
        echo -e "${G}✓ Search details saved:${N}"
        echo -e "  From:  $FROM"
        echo -e "  To:    $TO"
        echo -e "  Date:  $DATE"
        echo -e "  Class: $SEAT_CLASS"
        return 0
    fi

    echo
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "${W}Current search${N}"
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "  From:  ${C}${FROM}${N}"
    echo -e "  To:    ${C}${TO}${N}"
    echo -e "  Date:  ${C}${DATE}${N}"
    echo -e "  Class: ${C}${SEAT_CLASS}${N}"
    echo

    ask "Change any of these before scanning? [y/N]: " answer || true

    case "$answer" in
        y|Y|yes|YES)

            v="$(ask_date "New date (any format, e.g. 22-04-26 or 22-Apr-2026) [keep: $DATE]: " "$DATE")"
            if [[ -n "$v" && "$v" != "$DATE" ]]; then
                DATE="$v"
                set_url_param "date_of_journey" "$DATE"
            fi

            v="$(pick_station "New from_city" "$FROM")"
            if [[ -n "$v" && "$v" != "$FROM" ]]; then
                FROM="$v"
                set_url_param "from_city" "$FROM"
            fi

            v="$(pick_station "New to_city" "$TO")"
            if [[ -n "$v" && "$v" != "$TO" ]]; then
                TO="$v"
                set_url_param "to_city" "$TO"
            fi

            ask "New seat_class (type a name like S_CHAIR, or ALL) [keep: $SEAT_CLASS]: " v || v=""
            v="$(printf '%s' "$v" | tr '[:lower:]' '[:upper:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [[ -n "$v" ]]; then
                SEAT_CLASS="$v"
                set_url_param "seat_class" "$SEAT_CLASS"
            fi

            save_config

            echo
            echo -e "${G}✓ Search parameters updated:${N}"
            echo -e "  From:  $FROM"
            echo -e "  To:    $TO"
            echo -e "  Date:  $DATE"
            echo -e "  Class: $SEAT_CLASS"
            ;;
    esac
}

# ============================================================
# GET TRAINS
# ============================================================

get_trains() {
    jq -c '
        (
            .data.data.trains //
            .data.trains //
            .trains //
            []
        )[]
    ' "$1" 2>/dev/null
}

# ============================================================
# GET CLASSES
#
# Used both for discovery AND for the live seat check, so the
# two paths can never disagree about where classes live.
# ============================================================

get_classes() {
    jq -c '
        (
            .seat_types //
            .seat_classes //
            .classes //
            []
        )[]
    ' <<< "$1" 2>/dev/null
}

# ============================================================
# SAVE CONFIG
# ============================================================

save_config() {

    local trains_json
    local classes_json
    local tmp

    if (( ${#WANTED_TRAINS[@]} > 0 )); then
        trains_json="$(
            printf '%s\n' "${WANTED_TRAINS[@]}" |
            jq -R . |
            jq -s .
        )"
    else
        trains_json='[]'
    fi

    if (( ${#WANTED_CLASSES[@]} > 0 )); then
        classes_json="$(
            printf '%s\n' "${WANTED_CLASSES[@]}" |
            jq -R . |
            jq -s .
        )"
    else
        classes_json='[]'
    fi

    [[ "$INTERVAL" =~ ^[0-9]+$ ]] ||
        INTERVAL="$DEFAULT_INTERVAL"

    (( INTERVAL < MIN_INTERVAL )) &&
        INTERVAL="$MIN_INTERVAL"

    # In free mode the proxy URL is derived from the route, so keep
    # the stored direct-API url untouched for later JSON use.
    local url_to_save="$URL"
    if [[ "$MODE" == "free" ]] && [[ -f "$CONFIG" ]]; then
        url_to_save="$(jq -r '.url // empty' "$CONFIG")"
    fi

    tmp="${CONFIG}.tmp"

    if [[ -f "$CONFIG" ]] &&
       jq empty "$CONFIG" >/dev/null 2>&1; then

        jq \
            --arg url "$url_to_save" \
            --arg mode "$MODE" \
            --arg from "$FROM" \
            --arg to "$TO" \
            --arg date "$DATE" \
            --arg seat_class "$SEAT_CLASS" \
            --argjson trains "$trains_json" \
            --argjson classes "$classes_json" \
            --argjson interval "$INTERVAL" \
            '
            .url = $url
            | .mode = $mode
            | .from_city = $from
            | .to_city = $to
            | .date_of_journey = $date
            | .seat_class = $seat_class
            | .trains = $trains
            | .classes = $classes
            | .interval = $interval
            ' "$CONFIG" > "$tmp"

    else

        jq -n \
            --arg url "$url_to_save" \
            --arg mode "$MODE" \
            --arg from "$FROM" \
            --arg to "$TO" \
            --arg date "$DATE" \
            --arg seat_class "$SEAT_CLASS" \
            --argjson trains "$trains_json" \
            --argjson classes "$classes_json" \
            --argjson interval "$INTERVAL" \
            '{
                url: $url,
                mode: $mode,
                from_city: $from,
                to_city: $to,
                date_of_journey: $date,
                seat_class: $seat_class,
                headers: {},
                trains: $trains,
                classes: $classes,
                interval: $interval
            }' > "$tmp"
    fi

    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$CONFIG"
        chmod 600 "$CONFIG"
    else
        rm -f "$tmp"
        echo -e "${R}Could not save configuration.${N}"
        return 1
    fi
}

# ============================================================
# LOAD CONFIG
# ============================================================

load_config() {

    [[ -f "$CONFIG" ]] || return 1

    jq empty "$CONFIG" >/dev/null 2>&1 ||
        return 1

    URL="$(jq -r '.url // empty' "$CONFIG")"
    MODE="$(jq -r '.mode // "json"' "$CONFIG")"
    FROM="$(jq -r '.from_city // .from // empty' "$CONFIG")"
    TO="$(jq -r '.to_city // .to // empty' "$CONFIG")"
    DATE="$(jq -r '.date_of_journey // .date // empty' "$CONFIG")"
    SEAT_CLASS="$(jq -r '.seat_class // .seatClass // "ALL"' "$CONFIG")"

    INTERVAL="$(jq -r '.interval // 10' "$CONFIG")"

    [[ "$INTERVAL" =~ ^[0-9]+$ ]] ||
        INTERVAL="$DEFAULT_INTERVAL"

    (( INTERVAL < MIN_INTERVAL )) &&
        INTERVAL="$MIN_INTERVAL"

    WANTED_TRAINS=()
    WANTED_CLASSES=()

    while IFS= read -r x; do
        [[ -n "$x" ]] &&
            WANTED_TRAINS+=("$x")
    done < <(
        jq -r '.trains[]? // empty' "$CONFIG"
    )

    while IFS= read -r x; do
        [[ -n "$x" ]] &&
            WANTED_CLASSES+=("$x")
    done < <(
        jq -r '.classes[]? // empty' "$CONFIG"
    )

    if [[ "$MODE" == "free" ]]; then
        [[ -n "$FROM" && -n "$TO" && -n "$DATE" ]] || return 1
        build_free_url
    else
        [[ -n "$URL" ]] || return 1
    fi

    return 0
}

# ============================================================
# AUTH JSON
# ============================================================

prompt_auth_json() {

    echo
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "${W}Paste fresh Railway JSON${N}"
    echo -e "${D}Tampermonkey -> Export for Termux${N}"
    echo
    echo -e "${D}Paste complete JSON, then type END + Enter (or Ctrl+D)${N}"
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo

    local tmp jq_err line
    tmp="$(mktemp)"

    strip_paste_line() {
        printf '%s' "$1" | sed -e 's/\x1b\[200~//g' -e 's/\x1b\[201~//g' | tr -d '\r'
    }

    echo -e "${C}Waiting for your paste — long-press -> PASTE the JSON below,${N}"
    echo -e "${C}then type ${W}END${C} on its own line + Enter.${N}"
    echo

    local nlines=0
    while true; do
        if ! ask "json[$nlines]> " line; then
            echo
            break
        fi
        line="$(strip_paste_line "$line")"
        [[ "$(norm "$line")" == "end" ]] && break
        [[ "$line" == '```'* ]] && continue
        [[ "$(norm "$line")" == "." ]] && break
        printf '%s\n' "$line" >> "$tmp"
        nlines=$((nlines + 1))
        if [[ -z "$line" ]] && [[ -s "$tmp" ]] && jq -e '.url and .headers' "$tmp" >/dev/null 2>&1; then
            break
        fi
    done
    echo -e "${D}Received $nlines line(s). Checking...${N}"

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo -e "${R}Nothing pasted. Tip: long-press -> PASTE, then type END.${N}"
        return 1
    fi

    if ! jq_err="$(jq empty "$tmp" 2>&1)"; then
        echo -e "${R}That paste is not valid JSON.${N}"
        echo -e "${D}$(printf '%s' "$jq_err" | head -n 2)${N}"
        echo -e "${D}Tip: copy again via Tampermonkey Copy for Termux, paste once, then END.${N}"
        rm -f "$tmp"
        return 1
    fi

    if ! jq -e '.headers | type == "object"' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        echo -e "${R}JSON has no valid headers object (export the full Copy-for-Termux JSON).${N}"
        return 1
    fi

    if ! jq -e '.url | type == "string"' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        echo -e "${R}JSON has no url field. Re-export after doing a search.${N}"
        return 1
    fi

    # NOTE: never use `//= (... // empty)` here — when BOTH key
    # variants are absent, `empty` drops the ENTIRE document (jq exits
    # 0 with no output), which used to wipe the paste and break the
    # merge below with "invalid JSON text passed to --argjson".
    local normalized
    normalized="$(mktemp)"
    jq '
        .from_city //= .from
        | .to_city //= .to
        | .date_of_journey //= .date
        | .seat_class //= .seatClass
        | .seat_class //= "ALL"
    ' "$tmp" > "$normalized" && mv "$normalized" "$tmp" || rm -f "$normalized"

    # The normalize step must never empty the paste — re-verify.
    if ! jq -e '.url | type == "string"' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp" "$normalized"
        echo -e "${R}Paste lost its url during processing. Re-export and try again.${N}"
        return 1
    fi

    local old_trains='[]'
    local old_classes='[]'
    local old_interval="$INTERVAL"
    local new_trains='[]'
    local new_classes='[]'

    if [[ -f "$CONFIG" ]] &&
       jq empty "$CONFIG" >/dev/null 2>&1; then

        old_trains="$(jq -c '.trains // []' "$CONFIG")"
        old_classes="$(jq -c '.classes // []' "$CONFIG")"
        old_interval="$(jq -r '.interval // 10' "$CONFIG")"
    fi

    new_trains="$(jq -c '.trains // []' "$tmp")"
    new_classes="$(jq -c '.classes // []' "$tmp")"

    # Adopt pasted selections only when saved ones are empty AND the
    # pasted value is a real non-empty JSON array (never blank out).
    if [[ "$old_trains" == "[]" || "$old_trains" == "null" || -z "$old_trains" ]]; then
        if [[ -n "$new_trains" ]] && printf '%s' "$new_trains" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
            old_trains="$new_trains"
        else
            old_trains='[]'
        fi
    fi
    if [[ "$old_classes" == "[]" || "$old_classes" == "null" || -z "$old_classes" ]]; then
        if [[ -n "$new_classes" ]] && printf '%s' "$new_classes" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
            old_classes="$new_classes"
        else
            old_classes='[]'
        fi
    fi
    # Final guard: merge args must be valid JSON, or --argjson fails.
    printf '%s' "$old_trains" | jq empty >/dev/null 2>&1 || old_trains='[]'
    printf '%s' "$old_classes" | jq empty >/dev/null 2>&1 || old_classes='[]'

    [[ "$old_interval" =~ ^[0-9]+$ ]] ||
        old_interval="$DEFAULT_INTERVAL"

    (( old_interval < MIN_INTERVAL )) &&
        old_interval="$MIN_INTERVAL"

    local tmp_config
    tmp_config="${CONFIG}.tmp"

    jq \
        --argjson old_trains "$old_trains" \
        --argjson old_classes "$old_classes" \
        --argjson old_interval "$old_interval" \
        '
        .trains = $old_trains
        | .classes = $old_classes
        | .interval = $old_interval
        ' "$tmp" > "$tmp_config"

    if [[ ! -s "$tmp_config" ]]; then
        rm -f "$tmp" "$tmp_config"
        echo -e "${R}Could not create configuration.${N}"
        return 1
    fi

    mv "$tmp_config" "$CONFIG"
    chmod 600 "$CONFIG"

    rm -f "$tmp"

    load_config || {
        echo -e "${R}Could not load new JSON.${N}"
        return 1
    }

    echo
    echo -e "${G}✓ Auth JSON updated.${N}"
    echo -e "${D}✓ Train/class selections preserved.${N}"

    return 0
}


# ============================================================
# STARTUP AUTH QUESTION
# ============================================================

ask_auth_update() {

    if [[ ! -f "$CONFIG" ]]; then
        echo -e "${Y}No Railway configuration found.${N}"
        prompt_auth_json || exit 1
        return 0
    fi

    echo
    ask "Update Auth JSON? [y/N]: " answer || true

    case "$answer" in
        y|Y|yes|YES)
            prompt_auth_json || exit 1
            ;;
    esac
}

# ============================================================
# INTERVAL SETUP
# ============================================================

configure_interval() {

    echo
    echo -e "${W}Polling interval${N}"
    echo -e "${D}Minimum: ${MIN_INTERVAL}s | Default: ${DEFAULT_INTERVAL}s${N}"
    echo
    echo -e "Current interval: ${C}${INTERVAL}s${N}"

    ask "Change interval? [y/N]: " answer || true

    case "$answer" in

        y|Y|yes|YES)

            while true; do

                ask "Enter interval in seconds [${DEFAULT_INTERVAL}]: " value || value=""

                [[ -z "$value" ]] &&
                    value="$DEFAULT_INTERVAL"

                if [[ "$value" =~ ^[0-9]+$ ]] &&
                   (( value >= MIN_INTERVAL )); then

                    INTERVAL="$value"
                    save_config

                    echo -e "${G}✓ Interval saved: ${INTERVAL}s${N}"
                    break

                fi

                echo -e \
                    "${R}Invalid interval. Minimum is ${MIN_INTERVAL}s.${N}"

            done

            ;;

    esac
}

# ============================================================
# CURL HEADERS
# ============================================================

build_curl_headers() {

    CURL_HEADERS=()

    while IFS=$'\t' read -r key value; do

        [[ -z "$key" ]] && continue

        CURL_HEADERS+=(
            "-H"
            "$key: $value"
        )

    done < <(
        jq -r '
            .headers // {}
            | to_entries[]
            | [.key, (.value | tostring)]
            | @tsv
        ' "$CONFIG"
    )

    (( ${#CURL_HEADERS[@]} > 0 ))
}

# ============================================================
# API REQUEST
# ============================================================

api_request() {

    local output="$1"

    # Login-free mode: public proxy, no auth headers at all.
    if [[ "${MODE:-json}" == "free" ]]; then
        local code
        code="$(curl \
            --silent \
            --compressed \
            --connect-timeout 10 \
            --max-time 25 \
            -H "Accept: application/json" \
            -H "User-Agent: Mozilla/5.0" \
            "$URL" \
            -o "$output" \
            -w '%{http_code}' 2>/dev/null)" || code="000"
        [[ -n "$code" ]] || code="000"
        printf '%s' "$code"
        return 0
    fi

    if ! build_curl_headers; then
        echo -e "${R}No API headers found.${N}"
        return 99
    fi

    local code
    code="$(curl \
        --silent \
        --compressed \
        --connect-timeout 10 \
        --max-time 25 \
        "${CURL_HEADERS[@]}" \
        -H "Accept: application/json" \
        "$URL" \
        -o "$output" \
        -w '%{http_code}' 2>/dev/null)" || code="000"
    [[ -n "$code" ]] || code="000"
    printf '%s' "$code"
}

# ============================================================
# API ERROR
# ============================================================

show_api_error() {

    local code="$1"
    local body="$2"

    echo
    echo -e "${R}API request failed — HTTP $code${N}"

    if [[ -s "$body" ]]; then

        echo -e "${D}Server response:${N}"

        jq -r '.' "$body" 2>/dev/null |
            head -20

    fi

    echo
}

# ============================================================
# API TEST
# ============================================================

ensure_api_works() {

    while true; do

        local tmp
        local code

        tmp="$(mktemp)"

        echo -e "${C}Testing Railway API...${N}"

        code="$(api_request "$tmp")"

        if [[ "$code" == "200" ]] &&
           jq empty "$tmp" >/dev/null 2>&1; then

            echo -e "${G}✓ API request successful.${N}"

            rm -f "$tmp"
            return 0
        fi

        show_api_error "$code" "$tmp"

        if [[ "$code" == "401" || "$code" == "403" ]]; then

            rm -f "$tmp"

            echo -e "${Y}Authentication has expired.${N}"
            ask "Update Auth JSON? [y/N]: " answer || true

            case "$answer" in
                y|Y|yes|YES)

                    if prompt_auth_json; then
                        continue
                    fi
                    ;;

                *)
                    return 1
                    ;;
            esac

            return 1
        fi

        if [[ "$code" == "429" ]]; then
            rm -f "$tmp"
            echo -e "${Y}Rate limited. Waiting 30s...${N}"
            sleep 30
            continue
        fi

        if [[ "$code" =~ ^5[0-9][0-9]$ ]]; then
            rm -f "$tmp"
            echo -e "${Y}Railway server error. Retrying in 15s...${N}"
            sleep 15
            continue
        fi

        if [[ "$code" == "000" ]]; then
            rm -f "$tmp"
            echo -e "${Y}Network error. Retrying in 10s...${N}"
            sleep 10
            continue
        fi

        rm -f "$tmp"
        return 1

    done
}

# ============================================================
# DEBUG DUMP
#
# Run the script with --dump (or -d) to fetch one live
# response and print, per matched-looking train, the raw
# JSON keys available at the train level and at the seat-type
# level. Use this if seats are still reported as unavailable
# when the website shows otherwise — it tells you exactly
# which field names the live API is actually using, so the
# field lists in train_id()/train_name()/class_name()/
# seat_count() above can be extended if needed.
# ============================================================

debug_dump() {

    if ! load_config; then
        echo -e "${Y}No configuration found. Run the script normally first to set it up.${N}"
        exit 1
    fi

    local tmp
    local code

    tmp="$(mktemp)"

    echo -e "${C}Fetching live response for inspection...${N}"

    code="$(api_request "$tmp")"

    if [[ "$code" != "200" ]]; then
        show_api_error "$code" "$tmp"
        rm -f "$tmp"
        exit 1
    fi

    local dumpfile="$HOME/railway-debug.json"
    jq '.' "$tmp" > "$dumpfile" 2>/dev/null

    echo -e "${G}✓ Full raw response saved to:${N} $dumpfile"
    echo

    echo -e "${W}Top-level keys under each train object:${N}"
    get_trains "$tmp" | head -1 | jq -r 'keys_unsorted[]' 2>/dev/null | sed 's/^/  • /'

    echo
    echo -e "${W}Per-train summary (name/id as currently parsed):${N}"

    local i=1
    local train

    while IFS= read -r train; do

        [[ -z "$train" ]] && continue

        echo -e "  ${C}[$i]${N} name=$(train_name "$train")  id=$(train_id "$train")"

        echo -e "      ${D}seat-type-container keys found via get_classes:${N}"

        local st
        while IFS= read -r st; do
            [[ -z "$st" ]] && continue
            echo -e "        - class=$(class_name "$st")  parsed_available=$(seat_count "$st")  raw=$st"
        done < <(get_classes "$train")

        ((i++))

    done < <(get_trains "$tmp")

    rm -f "$tmp"

    echo
    echo -e "${Y}If parsed_available doesn't match what the website shows,${N}"
    echo -e "${Y}open $dumpfile and look at the real field name holding the count,${N}"
    echo -e "${Y}then add it to seat_count() near the top of the script.${N}"
}

# ============================================================
# EDIT MENU — press 'e' during the countdown to open
# ============================================================

edit_menu() {
    echo
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "${W}EDIT MENU${N}"
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo "  1) Date of journey  (currently: $DATE)"
    echo "  2) From city        (currently: $FROM)"
    echo "  3) To city          (currently: $TO)"
    echo "  4) Seat class       (currently: $SEAT_CLASS)"
    echo "  5) Trains selection"
    echo "  6) Classes selection"
    echo "  7) Interval         (currently: ${INTERVAL}s)"
    echo "  8) Paste new Auth JSON"
    echo "  9) Switch method     (currently: ${MODE:-json})"
    echo "  0) Back to monitoring"
    echo
    ask "Choice (0-9): " choice || choice=""

    local tmp code

    case "$choice" in
        1) v="$(ask_date "New date (any format, e.g. 22-04-26, 2026-04-22, 22-Apr-2026): " "")"
           if [[ -n "$v" ]]; then DATE="$v"; set_url_param "date_of_journey" "$DATE"; save_config; echo -e "${G}✓ Date updated: $DATE${N}"; else echo -e "${Y}No change.${N}"; fi ;;
        2) v="$(pick_station "New from_city" "$FROM")"
           [[ -n "$v" ]] && { FROM="$v"; set_url_param "from_city" "$FROM"; save_config; echo -e "${G}✓ Updated.${N}"; } ;;
        3) v="$(pick_station "New to_city" "$TO")"
           [[ -n "$v" ]] && { TO="$v"; set_url_param "to_city" "$TO"; save_config; echo -e "${G}✓ Updated.${N}"; } ;;
        4) ask "New seat_class (type a name like S_CHAIR, or ALL): " v || v=""; v="$(printf '%s' "$v" | tr '[:lower:]' '[:upper:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
           [[ -n "$v" ]] && { SEAT_CLASS="$v"; set_url_param "seat_class" "$SEAT_CLASS"; save_config; echo -e "${G}✓ Updated.${N}"; } ;;
        5) tmp="$(mktemp)"; code="$(api_request "$tmp")"
           if [[ "$code" == "200" ]] && discover_trains "$tmp"; then select_trains; else echo -e "${R}Could not refresh trains.${N}"; fi
           rm -f "$tmp" ;;
        6) tmp="$(mktemp)"; code="$(api_request "$tmp")"
           if [[ "$code" == "200" ]] && discover_classes "$tmp"; then select_classes; else echo -e "${R}Could not refresh classes.${N}"; fi
           rm -f "$tmp" ;;
        7) configure_interval ;;
        8) prompt_auth_json ;;
        9) choose_mode
           if [[ "$MODE" == "free" ]]; then
               build_free_url
               save_config
               echo -e "${G}✓ Switched to login-free. Next check uses the proxy.${N}"
           else
               save_config
               echo -e "${G}✓ Switched to JSON method.${N}"
               if ! has_json_headers; then
                   echo -e "${Y}No Auth JSON saved — paste it now.${N}"
                   prompt_auth_json || true
                   load_config || true
                   MODE="json"
               fi
           fi ;;
        0|"") ;;
        *) echo -e "${R}Invalid choice.${N}" ;;
    esac
}

# ============================================================
# DISCOVER TRAINS
# ============================================================

discover_trains() {

    local response="$1"

    TRAIN_JSON=()

    while IFS= read -r obj; do
        [[ -n "$obj" ]] &&
            TRAIN_JSON+=("$obj")
    done < <(
        get_trains "$response"
    )

    if (( ${#TRAIN_JSON[@]} == 0 )); then

        echo
        echo -e "${Y}No trains found in API response.${N}"
        echo -e "${D}Expected: .data.data.trains${N}"

        return 1
    fi

    echo
    echo -e "${W}Available trains:${N}"
    echo

    local i=1
    local obj
    local name
    local id

    for obj in "${TRAIN_JSON[@]}"; do

        name="$(train_name "$obj")"
        id="$(train_id "$obj")"

        [[ -z "$name" ]] && name="Train"
        [[ -z "$id" ]] && id="$name"

        echo -e \
            "  ${C}${i})${N} ${name} ${D}[ID: ${id}]${N}"

        ((i++))

    done

    echo

    return 0
}

# ============================================================
# SELECT TRAINS
# ============================================================

select_trains() {

    local count="${#TRAIN_JSON[@]}"

    if (( count == 0 )); then
        echo -e "${R}No trains in this response — check From/To/Date, then retry.${N}"
        return 1
    fi

    while true; do

        echo -e "${Y}Enter train numbers separated by spaces, or type train names.${N}"
        echo -e "${D}Example: 1 2  |  JAHANABAD  |  ALL for every train${N}"
        echo

        local selection
        ask "Train selection: " selection || { echo -e "${R}Input closed — keeping previous selection.${N}"; return 1; }

        WANTED_TRAINS=()

        if [[ "$(norm "$selection")" == "all" ]]; then

            local obj
            local id
            local name

            for obj in "${TRAIN_JSON[@]}"; do

                id="$(train_id "$obj")"
                name="$(train_name "$obj")"

                if [[ -n "$id" ]]; then
                    WANTED_TRAINS+=("$id")
                elif [[ -n "$name" ]]; then
                    WANTED_TRAINS+=("$name")
                fi

            done

        else

            local n
            local obj
            local id
            local name

            for n in $selection; do

                if [[ "$n" =~ ^[0-9]+$ ]] &&
                   (( n >= 1 && n <= count )); then

                    obj="${TRAIN_JSON[$((n-1))]}"

                    id="$(train_id "$obj")"
                    name="$(train_name "$obj")"

                    if [[ -n "$id" ]]; then
                        WANTED_TRAINS+=("$id")
                    elif [[ -n "$name" ]]; then
                        WANTED_TRAINS+=("$name")
                    fi

                else

                    # Typed text (name or ID) instead of a number — match it.
                    for obj in "${TRAIN_JSON[@]}"; do
                        id="$(train_id "$obj")"
                        name="$(train_name "$obj")"
                        if { [[ -n "$id" && "$(norm "$id")" == "$(norm "$n")" ]]; } ||
                           { [[ -n "$name" && "$(norm "$name")" == *"$(norm "$n")"* ]]; }; then
                            if [[ -n "$id" ]]; then
                                WANTED_TRAINS+=("$id")
                            else
                                WANTED_TRAINS+=("$name")
                            fi
                            break
                        fi
                    done

                fi

            done

        fi

        if (( ${#WANTED_TRAINS[@]} == 0 )); then
            echo
            echo -e "${R}No valid trains selected.${N}"
            echo
            continue
        fi

        save_config

        echo
        echo -e "${G}✓ Train selection saved:${N}"
        printf '  • %s\n' "${WANTED_TRAINS[@]}"

        return 0

    done
}

# ============================================================
# DISCOVER CLASSES
# ============================================================

discover_classes() {

    local response="$1"

    CLASS_NAMES=()

    while IFS= read -r c; do

        [[ -n "$c" ]] &&
            CLASS_NAMES+=("$c")

    done < <(

        get_trains "$response" |

        while IFS= read -r train; do

            get_classes "$train" |

            while IFS= read -r class_obj; do

                class_name "$class_obj"

            done

        done |

        sort -u
    )

    if (( ${#CLASS_NAMES[@]} == 0 )); then
        echo -e "${Y}No seat classes discovered.${N}"
        return 1
    fi

    echo
    echo -e "${W}Available seat classes:${N}"
    echo

    local i=1
    local c

    for c in "${CLASS_NAMES[@]}"; do
        echo -e "  ${C}${i})${N} $c"
        ((i++))
    done

    echo
    return 0
}

# ============================================================
# SELECT CLASSES
# ============================================================

select_classes() {

    local count="${#CLASS_NAMES[@]}"

    if (( count == 0 )); then
        echo -e "${R}No seat classes in this response — check From/To/Date, then retry.${N}"
        return 1
    fi

    while true; do

        echo -e "${Y}Enter class numbers, or type class names directly.${N}"
        echo -e "${D}Example: 1 2  |  S_CHAIR SNIGDHA  |  ALL for every class${N}"
        echo

        local selection

        ask "Class selection: " selection || { echo -e "${R}Input closed — keeping previous selection.${N}"; return 1; }

        WANTED_CLASSES=()

        if [[ "$(norm "$selection")" == "all" ]]; then

            WANTED_CLASSES=(
                "${CLASS_NAMES[@]}"
            )

        else

            local n

            for n in $selection; do

                if [[ "$n" =~ ^[0-9]+$ ]] &&
                   (( n >= 1 && n <= count )); then

                    WANTED_CLASSES+=(
                        "${CLASS_NAMES[$((n-1))]}"
                    )

                else

                    # Typed a class name directly — match it (case-insensitive).
                    local c
                    for c in "${CLASS_NAMES[@]}"; do
                        if [[ "$(norm "$c")" == "$(norm "$n")" ]]; then
                            WANTED_CLASSES+=("$c")
                            break
                        fi
                    done

                fi

            done

        fi

        if (( ${#WANTED_CLASSES[@]} == 0 )); then
            echo
            echo -e "${R}No valid classes selected.${N}"
            echo
            continue
        fi

        save_config

        echo
        echo -e "${G}✓ Class selection saved:${N}"
        printf '  • %s\n' "${WANTED_CLASSES[@]}"

        return 0

    done
}

# ============================================================
# MATCH TRAIN
# ============================================================

matches_train() {

    local obj="$1"

    local name
    local id
    local base
    local wanted
    local wanted_base

    name="$(norm "$(train_name "$obj")")"
    id="$(norm "$(train_id "$obj")")"
    base="$(norm "$(base_name "$(train_name "$obj")")")"

    for wanted in "${WANTED_TRAINS[@]}"; do

        wanted="$(norm "$wanted")"

        [[ -z "$wanted" ]] && continue

        # Exact ID.
        if [[ -n "$id" && "$id" == "$wanted" ]]; then
            return 0
        fi

        # Exact name.
        if [[ -n "$name" && "$name" == "$wanted" ]]; then
            return 0
        fi

        # Base name (ignores a trailing trip number that can
        # differ by day/direction for the same physical train).
        wanted_base="$(norm "$(base_name "$wanted")")"
        if [[ -n "$base" && -n "$wanted_base" && "$base" == "$wanted_base" ]]; then
            return 0
        fi

        # Partial name.
        if [[ -n "$name" && "$name" == *"$wanted"* ]]; then
            return 0
        fi

    done

    return 1
}

# ============================================================
# MATCH CLASS
# ============================================================

matches_class() {

    local class_obj="$1"
    local cname
    local wanted

    cname="$(norm "$(class_name "$class_obj")")"

    [[ -z "$cname" ]] &&
        return 1

    for wanted in "${WANTED_CLASSES[@]}"; do

        wanted="$(norm "$wanted")"

        [[ "$cname" == "$wanted" ]] &&
            return 0

        [[ "$cname" == *"$wanted"* ]] &&
            return 0
    done

    return 1
}

# ============================================================
# CHECK RESPONSE
# ============================================================

check_response() {

    local response="$1"

    if ! jq empty "$response" >/dev/null 2>&1; then
        echo -e "${R}Invalid API JSON.${N}"
        return 2
    fi

    local found=0
    local total_trains=0
    local matched_trains=0
    local matched_classes=0

    local train
    local st

    local train_display
    local train_number

    local cname
    local available

    while IFS= read -r train; do

        [[ -z "$train" ]] && continue

        total_trains=$((total_trains + 1))

        matches_train "$train" || continue

        matched_trains=$((matched_trains + 1))

        train_display="$(train_name "$train")"
        train_number="$(train_id "$train")"

        [[ -z "$train_display" ]] &&
            train_display="Train"

        [[ -z "$train_number" ]] &&
            train_number="?"

        while IFS= read -r st; do

            [[ -z "$st" ]] && continue

            matches_class "$st" || continue

            matched_classes=$((matched_classes + 1))

            cname="$(class_name "$st")"
            available="$(seat_count "$st")"

            [[ -z "$available" ]] &&
                available="0"

            # =================================================
            # NO BC.
            # Bash compares integer seat counts directly.
            # =================================================

            if [[ "$available" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                available="${available%%.*}"
            fi
            if [[ "$available" =~ ^[0-9]+$ ]] &&
               (( 10#$available > 0 )); then

                found=1

                echo
                echo -e "${G}"
                echo "╔════════════════════════════════════════════╗"
                echo "║             🚨 SEAT AVAILABLE!            ║"
                echo "╚════════════════════════════════════════════╝"
                echo -e "${N}"

                echo -e "${W}Train:${N}     $train_display"
                echo -e "${W}Train ID:${N}  $train_number"
                echo -e "${W}Class:${N}     $cname"
                echo -e "${W}Available:${N} ${G}${available}${N}"

                echo
                echo -e "${Y}🚨 BOOK NOW${N}"
                echo

                if command -v termux-notification >/dev/null 2>&1; then

                    termux-notification \
                        --title "🚨 Railway Seat Available" \
                        --content "$train_display — $cname — $available seat(s)" \
                        --priority high \
                        --sound

                fi

                open_booking_page
                ring_alarm

            fi

        done < <(
            get_classes "$train"
        )

    done < <(
        get_trains "$response"
    )

    if (( found == 0 )); then
        if (( total_trains == 0 )); then
            echo -e "${Y}Checked — API returned no trains. Check From/To/Date (or run --dump).${N}"
        elif (( matched_trains == 0 )); then
            echo -e "${Y}Checked — $total_trains train(s) returned, none match your selection.${N}"
            echo -e "${D}Tip: press e → 5 to reselect trains.${N}"
        elif (( matched_classes == 0 )); then
            echo -e "${Y}Checked — trains matched but none of your classes were found.${N}"
            echo -e "${D}Tip: press e → 6 to reselect classes.${N}"
        else
            echo -e "${G}✓ Checked — no seats available${N}"
        fi
    fi

    return 0
}

# ============================================================
# METHOD (login-free vs JSON)
# ============================================================

# Build the public-proxy URL from the route (no login needed).
build_free_url() {
    local f tc d
    f="$(printf '%s' "$FROM" | jq -sRr @uri)"
    tc="$(printf '%s' "$TO" | jq -sRr @uri)"
    d="$(printf '%s' "$DATE" | jq -sRr @uri)"
    URL="${FREE_BASE}?action=search_trips&from_city=${f}&to_city=${tc}&date_of_journey=${d}"
}

# First question at startup: which fetch method to use.
choose_mode() {
    echo
    echo -e "${W}How should train data be fetched?${N}"
    echo -e "  ${C}1)${N} Login-free (public proxy, no paste needed)"
    echo -e "  ${C}2)${N} JSON method (direct Railway API, needs Tampermonkey paste)"
    local def="1"
    [[ "$MODE" == "json" ]] && def="2"
    [[ "$MODE" == "free" ]] && def="1"
    local ans=""
    ask "Choose method [${def}]: " ans || true
    [[ -z "$ans" ]] && ans="$def"
    case "$ans" in
        1|free|FREE) MODE="free" ;;
        2|json|JSON) MODE="json" ;;
        *) echo -e "${Y}Keeping saved method: $MODE${N}" ;;
    esac
    echo -e "${G}✓ Method: $MODE${N}"
    save_config
}

# True when saved Auth JSON headers exist and are non-empty.
has_json_headers() {
    [[ -f "$CONFIG" ]] &&
    jq -e '.headers | type == "object" and length > 0' "$CONFIG" >/dev/null 2>&1
}

# One-shot login-free test: 200 + valid JSON + trains array present.
free_test_ok() {
    local code="$1" body="$2"
    [[ "$code" == "200" ]] || return 1
    jq empty "$body" >/dev/null 2>&1 || return 1
    jq -e '.data.trains | type == "array"' "$body" >/dev/null 2>&1
}

# Make sure route fields are filled (prompts for any missing one).
ensure_route_set() {
    local v=""
    while [[ -z "$FROM" || -z "$TO" || -z "$DATE" ]]; do
        echo -e "${Y}Route details are needed for searching.${N}"
        if [[ -z "$FROM" ]]; then
            v="$(pick_station "From city" "")" || { echo -e "${R}Input closed (EOF) — exiting.${N}"; return 1; }
            [[ -n "$v" ]] && FROM="$v"
        fi
        if [[ -z "$TO" ]]; then
            v="$(pick_station "To city" "")" || { echo -e "${R}Input closed (EOF) — exiting.${N}"; return 1; }
            [[ -n "$v" ]] && TO="$v"
        fi
        if [[ -z "$DATE" ]]; then
            v="$(ask_date "Date of journey (e.g. 22-04-26 or 22-Apr-2026): " "" || true)"
            if [[ -n "$v" ]]; then DATE="$v"; else echo -e "${R}Input closed (EOF) — exiting.${N}"; return 1; fi
        fi
    done
    set_url_param "from_city" "$FROM"
    set_url_param "to_city" "$TO"
    set_url_param "date_of_journey" "$DATE"
}

# JSON-method auth phase (used at startup and on free-method fallback).
json_auth_phase() {
    if has_json_headers; then
        ask_auth_update
    else
        echo -e "${Y}No Railway Auth JSON saved yet.${N}"
        prompt_auth_json || return 1
    fi
    load_config || {
        echo -e "${R}Failed to load configuration.${N}"
        return 1
    }
    MODE="json"
    ensure_api_works || return 1
}

# Switch to JSON method keeping previous settings; offers edit menu.
fallback_to_json() {
    echo
    echo -e "${Y}Login-free method failed — continuing with JSON method and previous settings.${N}"
    MODE="json"
    load_config || true
    if has_json_headers; then
        echo -e "${W}Previous JSON settings:${N} $FROM → $TO on $DATE"
        echo -e "${D}Press 'e' to edit, 'p' to paste new JSON, Enter to continue.${N}"
        local k=""
        ask_key 15 k || true
        echo
        if [[ "$k" == "e" || "$k" == "E" ]]; then
            edit_menu
        elif [[ "$k" == "p" || "$k" == "P" ]]; then
            prompt_auth_json || return 1
            load_config || return 1
        fi
        MODE="json"
        ensure_api_works || return 1
        return 0
    fi
    echo -e "${Y}No saved Auth JSON found — paste it now.${N}"
    prompt_auth_json || return 1
    load_config || return 1
    MODE="json"
    ensure_api_works || return 1
}

# ============================================================
# SELECTION VALIDITY — skip re-asking when saved selections
# still match the live data (kills the double-ask).
# ============================================================

# Every wanted train still matches at least one discovered train.
trains_selection_valid() {
    local w obj found saved
    saved=("${WANTED_TRAINS[@]}")
    (( ${#saved[@]} > 0 )) || return 1
    (( ${#TRAIN_JSON[@]} > 0 )) || return 1
    for w in "${saved[@]}"; do
        WANTED_TRAINS=("$w")
        found=1
        for obj in "${TRAIN_JSON[@]}"; do
            if matches_train "$obj"; then
                found=0
                break
            fi
        done
        WANTED_TRAINS=("${saved[@]}")
        (( found == 0 )) || return 1
    done
    return 0
}

# Every wanted class still exists in the discovered class list.
classes_selection_valid() {
    local w c ok
    (( ${#WANTED_CLASSES[@]} > 0 )) || return 1
    (( ${#CLASS_NAMES[@]} > 0 )) || return 1
    for w in "${WANTED_CLASSES[@]}"; do
        ok=1
        for c in "${CLASS_NAMES[@]}"; do
            if [[ "$(norm "$c")" == "$(norm "$w")" ]]; then
                ok=0
                break
            fi
        done
        (( ok == 0 )) || return 1
    done
    return 0
}

# ============================================================
# RECOMMENDATIONS — when the searched route has no seats, the
# API returns suggested alternate routes in
# .data.recommendations. Show them and ask (before monitoring
# starts) whether they should be watched too.
# ============================================================

offer_recommendations() {
    local response="$1"
    local items count
    count="$(jq -r '.data.recommendations | length' "$response" 2>/dev/null || echo 0)"
    [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) || return 0
    echo
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "${W}No seats yet — but the API suggests these alternates:${N}"
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    local i=1 item label
    items="$(jq -c '.data.recommendations[]' "$response" 2>/dev/null)"
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        label="$(train_name "$item")"
        if [[ -z "$label" || "$label" == "null" ]]; then
            label="$(train_id "$item")"
        fi
        if [[ -z "$label" || "$label" == "null" ]]; then
            label="$(jq -r 'tostring' <<< "$item" 2>/dev/null | head -c 120)"
        fi
        echo -e "  ${C}$i)${N} $label"
        ((i++))
    done <<< "$items"
    echo
    local ans=""
    ask "Watch these suggested routes too? [y/N]: " ans || true
    case "$ans" in
        y|Y|yes|YES)
            while IFS= read -r item; do
                [[ -z "$item" ]] && continue
                label="$(train_name "$item")"
                [[ -z "$label" || "$label" == "null" ]] && label="$(train_id "$item")"
                if [[ -n "$label" && "$label" != "null" ]]; then
                    WANTED_TRAINS+=("$label")
                fi
            done <<< "$items"
            echo -e "${G}✓ Added API suggestions to watched trains.${N}"
            ;;
    esac
    return 0
}

# ============================================================
# SELFTEST — pure-function checks, no network, no prompts left
# hanging (stdin-driven via ASK_NO_TTY). Run: ./rail.sh --selftest
# ============================================================

selftest() {
    local fail=0
    t() {
        if [[ "$2" == "$3" ]]; then
            echo "PASS: $1"
        else
            echo "FAIL: $1 (expected [$2], got [$3])"
            fail=$((fail + 1))
        fi
    }
    t "date DD-MM-YY" "22-Apr-2026" "$(normalize_date "22-04-26")"
    t "date ISO" "22-Apr-2026" "$(normalize_date "2026-04-22")"
    t "date DD-Mon-YYYY" "09-Sep-2026" "$(normalize_date "09-Sep-2026")"
    t "date garbage" "" "$(normalize_date "hello" || true)"
    t "seat nested online" "3" "$(seat_count '{"seat_counts":{"online":3,"offline":1}}')"
    t "seat flat" "5" "$(seat_count '{"available_seats":5}')"
    t "seat zero" "0" "$(seat_count '{"seat_counts":{"online":0}}')"
    t "train name by content" "JAHANABAD EXPRESS (826)" "$(train_name '{"train_model":"826","trip_number":"JAHANABAD EXPRESS (826)"}')"
    t "train id by content" "826" "$(train_id '{"train_model":"826","trip_number":"JAHANABAD EXPRESS (826)"}')"
    t "class name" "S_CHAIR" "$(class_name '{"type":"S_CHAIR"}')"
    STATIONS=(Dhaka Chattogram "Cox's Bazar" Biman_Bandar)
    build_station_keys
    t "station exact" "Dhaka" "$(station_matches "dhaka")"
    t "station compact spaces" "Cox's Bazar" "$(station_matches "cox bazar")"
    WANTED_CLASSES=("S_CHAIR")
    if matches_class '{"type":"S_CHAIR"}'; then echo "PASS: class match"; else echo "FAIL: class match"; fail=$((fail + 1)); fi
    if matches_class '{"type":"AC_S"}'; then echo "FAIL: class mismatch leaked"; fail=$((fail + 1)); else echo "PASS: class mismatch rejected"; fi
    pick1="$(printf 'dhaka\n1\n' | ASK_NO_TTY=1 pick_station "P" "" 2>/dev/null)"
    t "station picker option-pick" "Dhaka" "$pick1"
    # ask() on EOF must return 1 immediately (no hang)
    local v="SENTINEL"
    if ASK_NO_TTY=1 ask "q: " v < /dev/null; then
        echo "FAIL: ask EOF should return 1"; fail=$((fail + 1))
    else
        echo "PASS: ask EOF returns 1"
    fi
    [[ -z "$v" ]] || { echo "FAIL: ask EOF should clear VAR"; fail=$((fail + 1)); }
    # recommendations: shown + added on 'y'
    local fake
    fake="$(mktemp)"
    printf '%s' '{"data":{"trains":[],"recommendations":[{"trip_number":"NIGHT STAR (99)","train_model":"99"}]}}' > "$fake"
    WANTED_TRAINS=()
    ASK_NO_TTY=1 offer_recommendations "$fake" <<< "y" > /dev/null
    (( ${#WANTED_TRAINS[@]} == 1 )) && echo "PASS: recommendation added" || { echo "FAIL: recommendation not added"; fail=$((fail + 1)); }
    rm -f "$fake"
    # stations.txt ships with the repo and holds 100+ stations
    local sfile
    sfile="$(dirname "${BASH_SOURCE[0]:-$0}")/stations.txt"
    if [[ -s "$sfile" ]] && (( $(wc -l < "$sfile") >= 100 )); then
        echo "PASS: stations.txt ($(wc -l < "$sfile") stations)"
    else
        echo "FAIL: stations.txt missing/too small ($sfile)"; fail=$((fail + 1))
    fi
    if (( fail == 0 )); then echo "SELFTEST: all passed"; else echo "SELFTEST: $fail failure(s)"; fi
    return $fail
}

# ============================================================
# SETUP
# ============================================================

setup() {

    # --------------------------------------------------------
    # LOAD EXISTING CONFIG
    # --------------------------------------------------------

    # Load previous settings if any (never fatal — first run is fine).
    load_config || true

    # Old configs have no .mode — keep previous JSON behavior.
    [[ -z "$MODE" ]] && MODE="json"

    # --------------------------------------------------------
    # METHOD PROMPT (first question every startup)
    # --------------------------------------------------------

    choose_mode || exit 1

    # --------------------------------------------------------
    # CONFIRM SEARCH PARAMETERS (route / date / class)
    #
    # These come from whatever was baked into the pasted JSON
    # export. Show them explicitly and give a chance to change
    # any of them BEFORE the first API call — so choosing a
    # date 4-5 days ahead doesn't lock you out of changing it.
    # --------------------------------------------------------

    confirm_search_params

    ensure_route_set || exit 1

    # --------------------------------------------------------
    # INTERVAL
    # --------------------------------------------------------

    configure_interval

    # --------------------------------------------------------
    # METHOD TEST (login-free once, else JSON with edit option)
    # --------------------------------------------------------

    if [[ "$MODE" == "free" ]]; then
        build_free_url
        save_config

        echo -e "${C}Trying login-free method...${N}"

        local ftest fcode
        ftest="$(mktemp)"
        fcode="$(api_request "$ftest")"

        if free_test_ok "$fcode" "$ftest"; then
            echo -e "${G}✓ Login-free method works.${N}"
            rm -f "$ftest"
        else
            echo -e "${R}Login-free method failed (HTTP $fcode).${N}"
            rm -f "$ftest"
            fallback_to_json || exit 1
        fi
    else
        json_auth_phase || exit 1
    fi

    # --------------------------------------------------------
    # FRESH API RESPONSE
    # --------------------------------------------------------

    local tmp
    local code

    tmp="$(mktemp)"

    code="$(api_request "$tmp")"

    if [[ "$code" != "200" ]]; then

        rm -f "$tmp"

        if [[ "$MODE" == "free" ]]; then
            fallback_to_json || exit 1
        else
            ensure_api_works || exit 1
        fi

        tmp="$(mktemp)"
        code="$(api_request "$tmp")"

    fi

    if [[ "$code" != "200" ]]; then

        echo -e "${R}Could not retrieve train data.${N}"
        rm -f "$tmp"
        exit 1
    fi

    # --------------------------------------------------------
    # TRAINS
    # --------------------------------------------------------

    discover_trains "$tmp" || {
        rm -f "$tmp"
        exit 1
    }

    # --------------------------------------------------------
    # TRAIN SELECTION
    # --------------------------------------------------------

    if (( ${#WANTED_TRAINS[@]} == 0 )); then

        select_trains || exit 1

    elif trains_selection_valid; then

        echo
        echo -e "${G}✓ Using saved trains:${N}"
        printf '  • %s\n' "${WANTED_TRAINS[@]}"

    else

        echo
        echo -e "${W}Saved trains:${N}"
        printf '  • %s\n' "${WANTED_TRAINS[@]}"
        echo -e "${D}Saved selection no longer matches live trains.${N}"
        echo

        ask "Change train selection? [y/N]: " answer || true

        case "$answer" in
            y|Y|yes|YES)
                select_trains
                ;;
        esac

    fi

    # --------------------------------------------------------
    # CLASSES
    # --------------------------------------------------------

    discover_classes "$tmp" || true

    if (( ${#CLASS_NAMES[@]} > 0 )); then

        if (( ${#WANTED_CLASSES[@]} == 0 )); then

            select_classes || exit 1

        elif classes_selection_valid; then

            echo
            echo -e "${G}✓ Using saved classes:${N}"
            printf '  • %s\n' "${WANTED_CLASSES[@]}"

        else

            echo
            echo -e "${W}Saved classes:${N}"
            printf '  • %s\n' "${WANTED_CLASSES[@]}"
            echo -e "${D}Saved selection no longer matches live classes.${N}"
            echo

            ask "Change class selection? [y/N]: " answer || true

            case "$answer" in
                y|Y|yes|YES)
                    select_classes
                    ;;
            esac

        fi

    fi

    # Suggested alternate routes (if the API returned any) — ask
    # BEFORE monitoring starts whether to watch them too.
    offer_recommendations "$tmp" || true

    rm -f "$tmp"

    save_config
}

# ============================================================
# START
# ============================================================

# --------------------------------------------------------
# DEBUG MODE ENTRY POINT
# --------------------------------------------------------

if [[ "${1:-}" == "--dump" || "${1:-}" == "-d" ]]; then
    ensure_deps || exit 1
    debug_dump
    exit 0
fi

if [[ "${1:-}" == "--selftest" ]]; then
    selftest
    exit $?
fi

clear

echo -e "${C}"
echo "╔════════════════════════════════════════════╗"
echo "║       BANGLADESH RAILWAY MONITOR          ║"
echo "║              TERMUX EDITION               ║"
echo "╚════════════════════════════════════════════╝"
echo -e "${N}"

# ------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------

ensure_deps || exit 1

ensure_pager_tone || true

setup

# ============================================================
# MONITOR HEADER
# ============================================================

echo
echo -e "${C}"
echo "╔════════════════════════════════════════════╗"
echo "║              MONITOR STARTED              ║"
echo "╚════════════════════════════════════════════╝"
echo -e "${N}"

echo
echo -e "${W}Route:${N}    $FROM → $TO"
echo -e "${W}Date:${N}     $DATE"
echo -e "${W}Interval:${N} ${INTERVAL}s"
echo -e "${W}Method:${N}   ${MODE:-json}"

echo
echo -e "${D}Selected trains:${N}"

if (( ${#WANTED_TRAINS[@]} > 0 )); then
    printf '  • %s\n' "${WANTED_TRAINS[@]}"
else
    echo "  • ALL"
fi

echo
echo -e "${D}Selected classes:${N}"

if (( ${#WANTED_CLASSES[@]} > 0 )); then
    printf '  • %s\n' "${WANTED_CLASSES[@]}"
else
    echo "  • ALL"
fi

echo
echo -e "${G}Monitoring... Press Ctrl+C to stop.${N}"
echo -e "${D}Tip: run 't.sh --dump' any time to inspect the raw API fields.${N}"
echo

# ============================================================
# MAIN LOOP
# ============================================================

CHECK=0

while true; do

    ((CHECK++))

    TMP="$(mktemp)"

    CODE="$(api_request "$TMP")"

    # ========================================================
    # SUCCESS
    # ========================================================

    if [[ "$CODE" == "200" ]]; then

        printf \
            "\r\033[K${D}[%s] Check #%d${N}" \
            "$(date '+%H:%M:%S')" \
            "$CHECK"

        check_response "$TMP"

        rm -f "$TMP"

        echo

        # ----------------------------------------------------
        # COUNTDOWN (press 'e' any time to open the edit menu)
        # ----------------------------------------------------

        for ((remaining=INTERVAL; remaining>0; remaining--)); do

            printf \
                "\r\033[K${D}Next check in %2ds ${C}[press e to edit]${N}" \
                "$remaining"

            if ask_key 1 key; then
                if [[ "$key" == "e" || "$key" == "E" || "$key" == $'\x08' ]]; then
                    printf "\r\033[K"
                    edit_menu
                fi
            elif (( HAVE_TTY == 0 )); then
                sleep 1
            fi

        done

        printf "\r\033[K"

        continue
    fi

    # ========================================================
    # AUTH FAILURE
    # ========================================================

    if [[ "$CODE" == "401" || "$CODE" == "403" ]]; then

        rm -f "$TMP"

        if [[ "$MODE" == "free" ]]; then
            echo
            echo -e "${Y}Login-free proxy rejected the request — falling back to JSON method.${N}"
            if fallback_to_json; then
                echo
                continue
            fi
            echo -e "${R}Stopped.${N}"
            exit 1
        fi

        echo
        echo -e "${R}Authentication stopped working.${N}"
        echo

        ask "Update Auth JSON? [y/N]: " answer || true

        case "$answer" in

            y|Y|yes|YES)

                if prompt_auth_json; then

                    load_config || exit 1

                    echo
                    echo -e "${C}Testing new credentials...${N}"

                    if ensure_api_works; then
                        echo -e "${G}✓ Authentication restored.${N}"
                        echo
                        continue
                    fi

                fi

                echo -e "${R}Authentication update failed.${N}"
                exit 1
                ;;

            *)

                echo "Stopped."
                exit 1
                ;;

        esac
    fi

    # ========================================================
    # RATE LIMIT
    # ========================================================

    if [[ "$CODE" == "429" ]]; then

        rm -f "$TMP"

        echo
        echo -e "${Y}HTTP 429 — rate limited.${N}"
        echo "Waiting 30 seconds..."

        sleep 30

        continue
    fi

    # ========================================================
    # SERVER ERROR
    # ========================================================

    if [[ "$CODE" =~ ^5[0-9][0-9]$ ]]; then

        rm -f "$TMP"

        echo
        echo -e "${Y}HTTP $CODE — Railway server error.${N}"
        echo "Retrying in 15 seconds..."

        sleep 15

        continue
    fi

    # ========================================================
    # NETWORK ERROR
    # ========================================================

    if [[ "$CODE" == "000" ]]; then

        rm -f "$TMP"

        echo
        echo -e "${Y}Network error.${N}"
        echo "Retrying in 10 seconds..."

        sleep 10

        continue
    fi

    # ========================================================
    # OTHER ERROR
    # ========================================================

    show_api_error "$CODE" "$TMP"

    rm -f "$TMP"

    echo -e "${Y}Retrying in 10 seconds...${N}"

    sleep 10

done

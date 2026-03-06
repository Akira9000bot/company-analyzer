#!/bin/bash
# discover_earnings_url.sh - Try to find the latest earnings press release URL from company/IR site.
# Usage: YAHOO_SUMMARY_JSON=<path> TICKER=<SYMBOL> ./discover_earnings_url.sh
#   Or: ./discover_earnings_url.sh <path_to_yahoo_summary_json> <TICKER>
# Output: One line with the discovered URL, or nothing if not found.
# Used by fetch_data.sh when EARNINGS_URL and _earnings_url.txt are not set.
set -euo pipefail

YAHOO_SUMMARY="${YAHOO_SUMMARY_JSON:-${1:-}}"
TICKER="${TICKER:-${2:-}}"
[ -z "$YAHOO_SUMMARY" ] || [ ! -f "$YAHOO_SUMMARY" ] && exit 0
[ -z "$TICKER" ] && exit 0

WEBSITE=$(jq -r '.quoteSummary.result[0].assetProfile.website // empty' "$YAHOO_SUMMARY" 2>/dev/null || true)
[ -z "$WEBSITE" ] || [ "$WEBSITE" = "null" ] && exit 0

# Normalize: strip protocol and path, strip www.
DOMAIN=$(echo "$WEBSITE" | sed -E 's|^https?://||; s|^www\.||; s|/.*||; s|^[[:space:]]*||; s|[[:space:]]*$||')
[ -z "$DOMAIN" ] && exit 0

resolve_url() {
    local base="$1"
    local href="$2"
    local root
    href=$(echo "$href" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//; s/&amp;/\&/g')
    [ -z "$href" ] && return 1
    if echo "$href" | grep -qE '^https?://'; then
        echo "$href"
        return 0
    fi
    if echo "$href" | grep -qE '^//'; then
        echo "https:$href"
        return 0
    fi
    root=$(echo "$base" | sed -E 's|(https?://[^/]+).*|\1|')
    if echo "$href" | grep -qE '^/'; then
        echo "${root}${href}"
    else
        echo "${base%/}/${href}"
    fi
}

pick_best_url() {
    local base="$1"
    local html="$2"
    local href url score
    while IFS= read -r href; do
        [ -z "$href" ] && continue
        url=$(resolve_url "$base" "$href" || true)
        [ -z "$url" ] && continue
        if ! echo "$url" | grep -qE '^https?://[^/]+/'; then
            continue
        fi
        if echo "$url" | grep -qiE '(facebook|twitter|linkedin|youtube|login|signup|subscribe|email-alerts|q4inc\.com|powered-by-q4|\.pdf$)'; then
            continue
        fi

        score=0
        strong_signal=0
        echo "$url" | grep -qi '/news/news-details/' && score=$((score + 80))
        echo "$url" | grep -qi '/news/news-details/' && strong_signal=1
        echo "$url" | grep -qi '/press-release' && score=$((score + 60))
        echo "$url" | grep -qi '/press-release' && strong_signal=1
        echo "$url" | grep -qiE '(earnings|financial-results)' && score=$((score + 40))
        echo "$url" | grep -qiE '(earnings|financial-results)' && strong_signal=1
        echo "$url" | grep -qiE '(^|[^a-z])q[1-4]([^a-z]|$)|quarter|full-year' && score=$((score + 25))
        echo "$url" | grep -qi '/news/' && score=$((score + 15))
        echo "$url" | grep -qiE '(quarterly-and-annual-results|event-details|events-and-presentations|webcast|transcript)' && score=$((score - 120))

        if [ "$score" -gt 0 ] && [ "$strong_signal" = "1" ]; then
            printf '%04d %s\n' "$score" "$url"
        fi
    done < <(echo "$html" | grep -oE 'href="[^"]+' | sed 's/href="//' || true) | sort -nr | head -1 | sed 's/^[0-9][0-9][0-9][0-9] //'
}

# Common IR base URLs
for BASE in "https://investors.${DOMAIN}" "https://ir.${DOMAIN}" "https://${DOMAIN}/investors" "https://${DOMAIN}/ir"; do
    for PAGE in "${BASE}/news" "$BASE" "${BASE%/}/financials/quarterly-and-annual-results/default.aspx"; do
        HTML=$(curl -sL -A "Mozilla/5.0 (compatible; OpenClaw-Research/1.0)" --connect-timeout 8 --max-time 15 "$PAGE" 2>/dev/null || true)
        [ -z "$HTML" ] && continue
        URL=$(pick_best_url "$PAGE" "$HTML")
        if [ -n "$URL" ]; then
            echo "$URL"
            exit 0
        fi
    done
done
exit 0

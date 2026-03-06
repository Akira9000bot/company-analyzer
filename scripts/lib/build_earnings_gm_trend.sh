#!/bin/bash
# build_earnings_gm_trend.sh - Build last-4-quarter gross margin trend from earnings releases.
# Usage: EARNINGS_URL=<latest release or IR page> ./build_earnings_gm_trend.sh
# Output: JSON array of up to 4 quarterly gross margin percentages, latest first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/parse_earnings_gross_margin.sh"
EARNINGS_URL="${EARNINGS_URL:-${1:-}}"
[ -z "$EARNINGS_URL" ] && { echo "[]"; exit 0; }

ROOT=$(echo "$EARNINGS_URL" | sed -E 's|(https?://[^/]+).*|\1|')
PAGE1="$EARNINGS_URL"
PAGE2="${ROOT}/financials/quarterly-and-annual-results/default.aspx"

resolve_url() {
    local href="$1"
    href=$(echo "$href" | sed 's/&amp;/\&/g')
    if echo "$href" | grep -qE '^https?://'; then
        echo "$href"
    elif echo "$href" | grep -qE '^//'; then
        echo "https:$href"
    else
        echo "${ROOT}${href}"
    fi
}

extract_links() {
    local page_url="$1"
    curl -sL -A "Mozilla/5.0 (compatible; OpenClaw-Research/1.0)" --connect-timeout 10 --max-time 20 "$page_url" 2>/dev/null | \
        grep -oE '(https?:)?//[^"'\'' >]*news/news-details/[^"'\'' >]*|/news/news-details/[^"'\'' >]*' | \
        grep -iE '(earnings|financial-results|quarter|full-year)' | \
        while IFS= read -r href; do resolve_url "$href"; done | awk '!seen[$0]++' | \
        python3 -c 'import re, sys
def fiscal_period(url: str):
    text = url.lower()
    patterns = [
        (r"fourth-quarter(?:-and-full-year)?-(\d{4})", 4),
        (r"third-quarter-(\d{4})", 3),
        (r"second-quarter-(\d{4})", 2),
        (r"first-quarter-(\d{4})", 1),
        (r"full-year-(\d{4})", 4),
    ]
    for pattern, quarter in patterns:
        m = re.search(pattern, text)
        if m:
            return (int(m.group(1)), quarter)
    m = re.search(r"/news/news-details/(\d{4})/", text)
    return (int(m.group(1)) if m else 0, 0)
links = [line.strip() for line in sys.stdin if line.strip()]
for url in sorted(links, key=fiscal_period, reverse=True):
    print(url)'
}

LINKS="$(extract_links "$PAGE2" || true)"
[ -z "$LINKS" ] && LINKS="$(extract_links "$PAGE1" || true)"

[ -z "$LINKS" ] && { echo "[]"; exit 0; }

VALUES=""
COUNT=0
while IFS= read -r url; do
    [ -z "$url" ] && continue
    PARSED=$(EARNINGS_URL="$url" bash "$PARSER" 2>/dev/null || true)
    [ -z "$PARSED" ] && continue
    GAAP=$(echo "$PARSED" | awk -F= '/^LATEST_Q_GAAP_GM_PCT=/{print $2}')
    NONGAAP=$(echo "$PARSED" | awk -F= '/^LATEST_Q_NON_GAAP_GM_PCT=/{print $2}')
    VAL="$GAAP"
    if [ -z "$VAL" ] || [ "$VAL" = "N/A" ]; then
        VAL="$NONGAAP"
    fi
    if [[ -n "$VAL" && "$VAL" != "N/A" && "$VAL" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        VALUES="${VALUES}${VAL}"$'\n'
        COUNT=$((COUNT + 1))
    fi
    [ "$COUNT" -ge 4 ] && break
done <<< "$LINKS"

if [ -z "$VALUES" ]; then
    echo "[]"
else
    printf '%s' "$VALUES" | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)'
fi

#!/bin/bash
# parse_earnings_gross_margin.sh - Fetch an earnings release URL and extract metrics (GAAP/Non-GAAP gross margin, RPO, full-year non-GAAP net income, compute/AI segment growth).
# Usage: call with EARNINGS_URL set; outputs LATEST_Q_GAAP_GM_PCT, LATEST_Q_NON_GAAP_GM_PCT, RPO_MILLIONS, RPO_YOY_PCT, FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS, COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT (or N/A).
set -euo pipefail

LATEST_Q_GAAP_GM_PCT="N/A"
LATEST_Q_NON_GAAP_GM_PCT="N/A"
RPO_MILLIONS="N/A"
RPO_YOY_PCT="N/A"
FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS="N/A"
COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT="N/A"
FULL_YEAR_GUIDANCE_EPS_LOW="N/A"
FULL_YEAR_GUIDANCE_EPS_HIGH="N/A"

if [ -z "${EARNINGS_URL:-}" ]; then
    echo "LATEST_Q_GAAP_GM_PCT=N/A"
    echo "LATEST_Q_NON_GAAP_GM_PCT=N/A"
    echo "RPO_MILLIONS=N/A"
    echo "RPO_YOY_PCT=N/A"
    echo "FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS=N/A"
    echo "COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT=N/A"
    echo "FULL_YEAR_GUIDANCE_EPS_LOW=N/A"
    echo "FULL_YEAR_GUIDANCE_EPS_HIGH=N/A"
    exit 0
fi

# Fetch HTML, normalize spaces and newlines, strip tags for simpler parsing
RAW=$(curl -sL -A "Mozilla/5.0 (compatible; OpenClaw-Research/1.0)" --connect-timeout 10 --max-time 30 "$EARNINGS_URL" 2>/dev/null || echo "")
if [ -z "$RAW" ]; then
    echo "LATEST_Q_GAAP_GM_PCT=N/A"
    echo "LATEST_Q_NON_GAAP_GM_PCT=N/A"
    echo "RPO_MILLIONS=N/A"
    echo "RPO_YOY_PCT=N/A"
    echo "FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS=N/A"
    echo "COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT=N/A"
    echo "FULL_YEAR_GUIDANCE_EPS_LOW=N/A"
    echo "FULL_YEAR_GUIDANCE_EPS_HIGH=N/A"
    exit 0
fi

# Strip HTML tags and collapse whitespace so we can grep for patterns
TEXT=$(echo "$RAW" | sed 's/<[^>]*>//g' | tr '\n' ' ' | sed 's/  */ /g')

# Some IR files point to a quarterly-results landing page instead of the actual earnings release.
# If the page has no earnings metrics but contains news-details links, follow the newest-looking one.
if { echo "$EARNINGS_URL" | grep -qiE 'quarterly-and-annual-results|quarterly-results'; } || ! echo "$TEXT" | grep -qiE 'GAAP gross margin|Non-GAAP gross margin|Remaining Performance Obligations|RPO|Other revenue'; then
    ROOT=$(echo "$EARNINGS_URL" | sed -E 's|(https?://[^/]+).*|\1|')
    ALT_URL=$(echo "$RAW" | grep -oE '(https?:)?//[^"'\'' >]*news/news-details/[^"'\'' >]*|/news/news-details/[^"'\'' >]*' | grep -iE '(earnings|financial-results|quarter|full-year)' | sed 's/&amp;/\&/g' | while IFS= read -r href; do
        if echo "$href" | grep -qE '^https?://'; then
            echo "$href"
        elif echo "$href" | grep -qE '^//'; then
            echo "https:$href"
        else
            echo "${ROOT}${href}"
        fi
    done | sort -u | tail -1 || true)
    if [ -n "$ALT_URL" ] && [ "$ALT_URL" != "$EARNINGS_URL" ]; then
        ALT_RAW=$(curl -sL -A "Mozilla/5.0 (compatible; OpenClaw-Research/1.0)" --connect-timeout 10 --max-time 30 "$ALT_URL" 2>/dev/null || echo "")
        if [ -n "$ALT_RAW" ]; then
            RAW="$ALT_RAW"
            EARNINGS_URL="$ALT_URL"
            TEXT=$(echo "$RAW" | sed 's/<[^>]*>//g' | tr '\n' ' ' | sed 's/  */ /g')
        fi
    fi
fi

# Avoid matching "GAAP" inside "Non-GAAP": mask Non-GAAP before GAAP extraction
TEXT_GAAP=$(echo "$TEXT" | sed 's/Non-GAAP gross margin/__NONGAAP__/gi')

# First percentage (XX.X) after "GAAP gross margin" = latest quarter (standalone, not inside Non-GAAP)
if echo "$TEXT_GAAP" | grep -qE 'GAAP gross margin'; then
    VAL=$(echo "$TEXT_GAAP" | sed 's/.*GAAP gross margin[^0-9]*/ /' | grep -oE '[0-9]{1,2}\.[0-9]+' | head -1 || true)
    if [ -n "$VAL" ] && [ "$(echo "scale=2; $VAL >= 1 && $VAL <= 100" | bc 2>/dev/null)" = "1" ]; then
        LATEST_Q_GAAP_GM_PCT="$VAL"
    fi
fi

# First percentage after "Non-GAAP gross margin" = latest quarter
if echo "$TEXT" | grep -qiE 'non-?GAAP gross margin'; then
    VAL=$(echo "$TEXT" | sed 's/.*non-gaap gross margin[^0-9]*/ /i' | grep -oE '[0-9]{1,2}\.[0-9]+' | head -1 || true)
    if [ -n "$VAL" ] && [ "$(echo "scale=2; $VAL >= 1 && $VAL <= 100" | bc 2>/dev/null)" = "1" ]; then
        LATEST_Q_NON_GAAP_GM_PCT="$VAL"
    fi
fi

# --- RPO (Remaining Performance Obligations): value in millions and YoY %
# e.g. "RPO of $353.8 million grew 55% year over year" or "RPO ... were $354 million, up 55%"
if echo "$TEXT" | grep -qiE 'RPO|remaining performance obligation'; then
    RPO_VAL=$(echo "$TEXT" | grep -oE 'RPO[^$]*\$[0-9][0-9,.]*' | head -1 | grep -oE '[0-9][0-9,.]*' | head -1 | tr -d ',') || true
    if [ -z "$RPO_VAL" ]; then
        RPO_VAL=$(echo "$TEXT" | grep -oE '\$[0-9][0-9,.]* *million' | head -1 | grep -oE '[0-9][0-9,.]*' | tr -d ',') || true
    fi
    if [ -n "$RPO_VAL" ]; then
        RPO_MILLIONS="$RPO_VAL"
    fi
    # Prefer percentage in the RPO sentence (e.g. "RPO ... grew 55% year over year" or "RPO ... $354 million, up 55%")
    RPO_SNIP=$(echo "$TEXT" | sed 's/.*RPO[^0-9]*\$[0-9][0-9,.]* *million[^.]*/\nRPO_SNIP:/' | grep 'RPO_SNIP:' | head -1 || true)
    RPO_PCT=$(echo "$RPO_SNIP" | grep -oE 'grew [0-9]{1,3} *%|up [0-9]{1,3} *%' | head -1 | grep -oE '[0-9]{1,3}') || true
    if [ -z "$RPO_PCT" ]; then
        RPO_PCT=$(echo "$TEXT" | grep -oE 'RPO[^0-9]*[0-9]{1,3} *% *year over year' | grep -oE '[0-9]{1,3}' | head -1) || true
    fi
    if [ -n "$RPO_PCT" ] && [ "$(echo "scale=2; $RPO_PCT >= 0 && $RPO_PCT <= 200" | bc 2>/dev/null)" = "1" ]; then
        RPO_YOY_PCT="$RPO_PCT"
    fi
fi

# --- Full year non-GAAP net income (millions) - e.g. "Non-GAAP net income of $19.7 million, compared to ... in fiscal 2024"
# Prefer the occurrence near "fiscal 20XX" (full year) over quarterly
if echo "$TEXT" | grep -qiE 'non-GAAP net income of \$[0-9]'; then
    VAL=$(echo "$TEXT" | grep -oiE 'non-GAAP net income of \$[0-9]+\.?[0-9]* *million[^.]*fiscal' | head -1 | grep -oE '[0-9]+\.?[0-9]*' | head -1) || true
    if [ -z "$VAL" ]; then
        VAL=$(echo "$TEXT" | grep -oiE 'non-GAAP net income of \$[0-9]+\.?[0-9]* *million' | head -1 | grep -oE '[0-9]+\.?[0-9]*') || true
    fi
    if [ -n "$VAL" ]; then
        FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS="$VAL"
    fi
fi

# --- Compute / AI / Other segment revenue growth YoY % - e.g. "Other revenue of $6.4 million, representing 78% year-over-year growth"
if echo "$TEXT" | grep -qiE 'other revenue|representing [0-9]+% year-over-year'; then
    VAL=$(echo "$TEXT" | grep -oiE 'other revenue of \$[0-9.]+ million, representing [0-9]{1,3} *%' | head -1 | grep -oE '[0-9]{1,3} *%' | grep -oE '[0-9]{1,3}') || true
    if [ -z "$VAL" ]; then
        VAL=$(echo "$TEXT" | grep -oE 'representing [0-9]{1,3} *% *year-over-year' | head -1 | grep -oE '[0-9]{1,3}') || true
    fi
    if [ -n "$VAL" ] && [ "$(echo "scale=2; $VAL >= -50 && $VAL <= 500" | bc 2>/dev/null)" = "1" ]; then
        COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT="$VAL"
    fi
fi

# --- Full year guidance EPS range from the earnings release table.
# Example: "First Quarter and Full Year 2026 Guidance ... Non-GAAP Net Income per share ... $0.07 - $0.10 $0.23 - $0.29"
GUIDANCE_SNIP=$(echo "$TEXT" | grep -oE 'First Quarter and Full Year [0-9]{4} Guidance.*A reconciliation[^.]*' | head -1 || true)
if [ -n "$GUIDANCE_SNIP" ] && echo "$GUIDANCE_SNIP" | grep -qiE 'Non-GAAP Net Income per share'; then
    RANGE_LINE=$(echo "$GUIDANCE_SNIP" | sed -E 's/.*Non-GAAP Net Income per share[^$]*\$([0-9]+\.[0-9]+) *- *\$([0-9]+\.[0-9]+) *\$([0-9]+\.[0-9]+) *- *\$([0-9]+\.[0-9]+).*/\1 \2 \3 \4/' || true)
    if echo "$RANGE_LINE" | grep -qE '^[0-9]+\.[0-9]+ [0-9]+\.[0-9]+ [0-9]+\.[0-9]+ [0-9]+\.[0-9]+$'; then
        FULL_YEAR_GUIDANCE_EPS_LOW=$(echo "$RANGE_LINE" | awk '{print $3}')
        FULL_YEAR_GUIDANCE_EPS_HIGH=$(echo "$RANGE_LINE" | awk '{print $4}')
    fi
fi

echo "LATEST_Q_GAAP_GM_PCT=${LATEST_Q_GAAP_GM_PCT:-N/A}"
echo "LATEST_Q_NON_GAAP_GM_PCT=${LATEST_Q_NON_GAAP_GM_PCT:-N/A}"
echo "RPO_MILLIONS=${RPO_MILLIONS:-N/A}"
echo "RPO_YOY_PCT=${RPO_YOY_PCT:-N/A}"
echo "FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS=${FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS:-N/A}"
echo "COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT=${COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT:-N/A}"
echo "FULL_YEAR_GUIDANCE_EPS_LOW=${FULL_YEAR_GUIDANCE_EPS_LOW:-N/A}"
echo "FULL_YEAR_GUIDANCE_EPS_HIGH=${FULL_YEAR_GUIDANCE_EPS_HIGH:-N/A}"
echo "RESOLVED_EARNINGS_URL=${EARNINGS_URL:-}"

#!/bin/bash
#
# fetch_data.sh - Free data acquisition (IR pages → SEC fallback)
#

TICKER="${1:-}"
[ -z "$TICKER" ] && { echo "Usage: ./fetch_data.sh <TICKER>"; exit 1; }

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')
DATA_DIR="/tmp/company-analyzer-cache"
DATA_FILE="$DATA_DIR/${TICKER_UPPER}_data.json"

mkdir -p "$DATA_DIR"

# Check if data already exists (7-day cache)
if [ -f "$DATA_FILE" ]; then
    AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$DATA_FILE" 2>/dev/null || echo 0) ) / 86400 ))
    if [ $AGE_DAYS -lt 7 ]; then
        echo "✅ Using cached data ($AGE_DAYS days old)"
        echo "   $DATA_FILE"
        exit 0
    fi
fi

echo "📊 Fetching data for $TICKER_UPPER..."

# Try to get CIK from SEC
CIK=$(curl -s "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${TICKER_UPPER}&type=10-K&dateb=&owner=include&count=1&output=atom" 2>/dev/null | grep -o '<cik>[^<]*' | head -1 | sed 's/<cik>//' || echo "")

# Create data structure
cat > "$DATA_FILE" <<EOF
{
  "ticker": "$TICKER_UPPER",
  "cik": "${CIK:-unknown}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "data_sources": {
    "ir_page": "https://investor.${TICKER_UPPER,,}.com (verify)",
    "sec_edgar": "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${TICKER_UPPER}"
  },
  "financial_metrics": {
    "revenue": "[Fill from 10-K/Q]",
    "revenue_growth": "[Fill from 10-K/Q]",
    "gross_margin": "[Fill from 10-K/Q]",
    "operating_margin": "[Fill from 10-K/Q]",
    "fcf_margin": "[Fill from 10-K/Q]",
    "rpo": "[Fill if SaaS]"
  },
  "sections": {
    "business_description": "[Paste from 10-K Item 1]",
    "md_and_a": "[Paste from 10-K Item 7]",
    "risk_factors": "[Paste from 10-K Item 1A]"
  }
}
EOF

echo ""
echo "✅ Created: $DATA_FILE"
echo ""
echo "Next steps:"
echo "1. Visit: https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${TICKER_UPPER}"
echo "2. Find latest 10-K or 10-Q filing"
echo "3. Edit: $DATA_FILE"
echo "4. Run: ./analyze.sh $TICKER_UPPER"

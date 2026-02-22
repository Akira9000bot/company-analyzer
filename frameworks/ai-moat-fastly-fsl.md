# Framework 03: AI Moat Analysis — Fastly (FSLY)

## Company Overview

**Fastly** is an edge cloud platform focused on content delivery and edge computing. Unlike Cloudflare's broad "network as a service" approach, Fastly targets **developer-focused, high-performance use cases** with its **Compute@Edge** platform.

### Key Differentiators:
- **Compute@Edge**: WebAssembly-based edge computing (Rust, JavaScript)
- **High-performance focus**: Sub-150ms cold starts, deterministic performance
- **Developer-centric**: API-first, granular control, real-time log streaming
- **Smaller network**: ~100-150 PoPs vs Cloudflare's 300+ (quality over quantity)

---

## The Four Lenses Analysis

### 1️⃣ NETWORK EFFECTS

| Aspect | Assessment | Score |
|--------|-----------|-------|
| **Data Network Effects** | ⚠️ WEAK — Fastly processes traffic but doesn't aggregate/cross-pollinate learnings across customers | 2/5 |
| **Developer Ecosystem** | ⚠️ MODERATE — Strong technical reputation, but smaller ecosystem than Cloudflare Workers | 3/5 |
| **Platform Stickiness** | ✅ STRONG — Complex edge logic (VCL, WASM) creates switching costs | 4/5 |

**Verdict**: Limited classic network effects. The moat here is **technical switching costs**, not self-reinforcing network dynamics.

---

### 2️⃣ DISTRIBUTION

| Aspect | Assessment | Score |
|--------|-----------|-------|
| **Sales Motion** | ✅ STRONG — Land-and-expand with enterprise; high NRR (~115-120%) | 4/5 |
| **Self-Serve** | ⚠️ MODERATE — Developer-friendly but less "bottoms-up" viral than Cloudflare | 3/5 |
| **Channel Partners** | ⚠️ WEAK — Smaller partner ecosystem vs hyperscalers | 2/5 |
| **Geographic Reach** | ⚠️ MODERATE — Good coverage but smaller footprint | 3/5 |

**Verdict**: Solid enterprise sales machine with strong retention, but lacks the viral developer adoption of competitors.

---

### 3️⃣ AI-SPECIFIC MOATS

| Aspect | Assessment | Score |
|--------|-----------|-------|
| **AI/ML Infrastructure** | ⚠️ EMERGING — Compute@Edge supports AI inference workloads; partnerships with model providers | 2/5 |
| **Proprietary AI Features** | ❌ WEAK — No significant first-party AI products (unlike Cloudflare's AI Gateway, Workers AI) | 1/5 |
| **Data Advantage for AI** | ❌ NONE — No unique data moat; doesn't train models on customer traffic | 1/5 |
| **AI Talent/Ecosystem** | ⚠️ MODERATE — Technical credibility attracts AI developers but no breakout AI products | 2/5 |

**Verdict**: Fastly is **lagging in AI-native features**. Compute@Edge is architecturally capable (WASM is good for inference), but they haven't productized AI the way Cloudflare has.

---

### 4️⃣ SWITCHING COSTS / DATA MOAT

| Aspect | Assessment | Score |
|--------|-----------|-------|
| **Code/Config Lock-in** | ✅ STRONG — VCL (Varnish), WASM modules, edge logic is non-trivial to migrate | 4/5 |
| **Data Gravity** | ⚠️ MODERATE — Real-time logging, edge storage creates some stickiness | 3/5 |
| **Integration Complexity** | ✅ STRONG — Deep integration into application architecture | 4/5 |

**Verdict**: **Technical switching costs are Fastly's core moat**. This is genuine but defensively positioned.

---

## Competitive Position: The 3-Player Market

```
┌─────────────────┬─────────────────┬─────────────────┐
│   CLOUDFLARE    │     FASTLY      │   AWS/GCP/Azure │
│   (Broad)       │   (Focused)     │   (Integrated)  │
├─────────────────┼─────────────────┼─────────────────┤
│ • 300+ PoPs     │ • ~100-150 PoPs │ • CloudFront/   │
│ • Developer-led │ • Enterprise-led│   Cloud CDN     │
│ • Network as    │ • Performance-  │ • Lambda@Edge   │
│   a service     │   centric       │ • Tight AWS     │
│ • AI-forward    │ • Compute@Edge  │   integration   │
│                 │                 │                 │
│ Market Cap:     │ Market Cap:     │ Market Cap:     │
│ ~$35B           │ ~$2B            │ Hyperscalers    │
└─────────────────┴─────────────────┴─────────────────┘
```

### Fastly's Position:
- **Niche**: High-performance, latency-sensitive applications
- **Customers**: Stripe, Shopify, The New York Times, GitHub (premium customers)
- **Trade-off**: Fewer PoPs but better per-node performance; deterministic caching

---

## Moat Rating: **ROBUST** (But Not Antifragile)

### Verdict: 🟡 **ROBUST** — 6/10

**Why Robust (not Fragile):**
1. ✅ **Technical switching costs** from edge code/configurations
2. ✅ **Strong retention** in enterprise segment
3. ✅ **Differentiated architecture** (quality over quantity PoPs)
4. ✅ **Premium positioning** attracts customers who value performance

**Why Not Antifragile:**
1. ❌ **No AI-specific moat** — they're a platform, not an AI beneficiary
2. ❌ **Smaller network** = less data to learn from
3. ❌ **No viral growth loop** — relies on sales-led expansion
4. ❌ **AI disruption risk** — if AI changes how apps are built/architected, Fastly's moat could erode

---

## Key Risks

| Risk | Severity | Notes |
|------|----------|-------|
| **AI commoditization** | HIGH | If AI inference becomes standard table stakes, Fastly may lose differentiation |
| **Cloudflare's AI push** | HIGH | Cloudflare Workers AI is a direct threat to Compute@Edge |
| **Hyperscaler bundling** | MEDIUM | AWS/GCP can bundle CDN with compute/storage at zero marginal cost |
| **Network scale disadvantage** | MEDIUM | Smaller PoP footprint = less coverage for edge AI workloads |

---

## Summary

Fastly has a **genuine but narrow moat** built on technical excellence and enterprise relationships. Their Compute@Edge platform is architecturally sound, but they haven't yet translated this into an **AI-native advantage**. In a world where AI becomes central to edge workloads, Fastly risks being squeezed between:

- **Cloudflare** (developer-friendly, AI-forward, larger network)
- **Hyperscalers** (bundled, integrated, massive scale)

**Investment Implication**: Fastly is a **quality business in a consolidating market**, but its moat is **not strengthening with AI disruption**. They need to either:
1. Accelerate AI product development
2. Double down on ultra-low-latency niche (real-time apps, gaming, fintech)
3. Pursue strategic M&A to acquire AI capabilities

---

*Analysis Date: 2026-02-21*
*Framework: Four Lenses AI Moat Analysis*

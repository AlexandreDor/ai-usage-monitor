Here's the full OpenClaw design system scraped and compiled for your token limits dashboard:

---

## 🎨 OpenClaw Design System — Complete Reference

---

### 🖋 Typography

**Fonts Used:**
- **Display / Headings:** `"Clash Display", system-ui, sans-serif` — used for all titles, section headers, card labels, buttons
- **Body:** `"Satoshi", system-ui, sans-serif` — used for body copy, descriptions, inputs
- **Mono:** `"SF Mono", "Fira Code", "JetBrains Mono", monospace` — code blocks, terminal UI, small labels

**Loading these fonts:** Both Clash Display and Satoshi are from [fontshare.com](https://www.fontshare.com/) (free). Add to your project:
```html
<link href="https://api.fontshare.com/v2/css?f[]=clash-display@400,500,600,700&f[]=satoshi@400,500,700&display=swap" rel="stylesheet">
```

**Typography Scale:**
- H1 (hero title): `clamp(3rem, 10vw, 4.5rem)`, weight `700`, letter-spacing `-0.03em`, line-height `1`
- Section titles: `1.4rem`, weight `600`, font-display
- Card titles: `1rem`, weight `600`
- Body text: `1.1rem`, line-height `1.7`
- Small/muted: `0.85rem–0.9rem`
- Mono labels: `0.7rem–0.9rem`

---

### 🎨 Color Palette (CSS Variables)

```css
:root {
  /* === BACKGROUNDS === */
  --bg-deep: #050810;          /* Main page background */
  --bg-surface: #0a0f1a;       /* Card surfaces */
  --bg-elevated: #111827;      /* Elevated surfaces, code blocks */

  /* === BRAND COLORS === */
  --coral-bright: #ff4d4d;     /* Primary accent — buttons, icons, links */
  --coral-mid: #e63946;        /* Hover states */
  --coral-dark: #991b1b;       /* Gradient end, darker accents */

  --cyan-bright: #00e5cc;      /* Secondary accent — hover states, glows */
  --cyan-mid: #14b8a6;         /* Softer cyan */
  --cyan-glow: rgba(0, 229, 204, 0.4);

  /* === TEXT === */
  --text-primary: #f0f4ff;     /* Main text */
  --text-secondary: #8892b0;   /* Body/description text */
  --text-muted: #5a6480;       /* Placeholders, timestamps, hints */

  /* === BORDERS === */
  --border-subtle: rgba(136, 146, 176, 0.15);  /* Default card borders */
  --border-accent: rgba(255, 77, 77, 0.3);     /* Hover/active borders */

  /* === SURFACES === */
  --surface-card: rgba(10, 15, 26, 0.65);
  --surface-card-strong: rgba(10, 15, 26, 0.8);
  --surface-overlay: rgba(0, 0, 0, 0.3);
  --surface-interactive: rgba(255, 255, 255, 0.1);
  --surface-interactive-hover: rgba(255, 255, 255, 0.2);
  --surface-cyan-soft: rgba(0, 229, 204, 0.15);
  --surface-coral-soft: rgba(255, 77, 77, 0.15);
  --surface-inset-highlight: rgba(255, 255, 255, 0.05);

  /* === SHADOWS/GLOWS === */
  --shadow-coral-soft: rgba(255, 77, 77, 0.15);
  --shadow-coral-mid: rgba(255, 77, 77, 0.25);
  --shadow-coral-strong: rgba(255, 77, 77, 0.35);
  --shadow-cyan-soft: rgba(0, 229, 204, 0.15);

  /* === LOGO/BRAND GRADIENTS === */
  --logo-glow: rgba(255, 77, 77, 0.4);
  --logo-glow-hover: rgba(0, 229, 204, 0.6);
  --logo-gradient-start: #ff4d4d;
  --logo-gradient-end: #991b1b;
}
```

---

### 🌌 Background System

The background has **3 layers stacked** (all `position: fixed; inset: 0; pointer-events: none; z-index: 0`):

**Layer 1 — Page base (body):**
```css
body {
  background: #050810;
}
```

**Layer 2 — Nebula (soft color glow blobs):**
```css
.nebula {
  background:
    radial-gradient(ellipse 80% 50% at 20% 20%, rgba(255, 77, 77, 0.12), transparent 50%),
    radial-gradient(ellipse 60% 60% at 80% 30%, rgba(0, 229, 204, 0.08), transparent 50%),
    radial-gradient(ellipse 90% 70% at 50% 90%, rgba(255, 77, 77, 0.06), transparent 50%);
}
```

**Layer 3 — Stars (twinkling dot pattern):**
```css
.stars {
  background-image:
    radial-gradient(2px 2px at 20px 30px, rgba(255,255,255,.8), transparent),
    radial-gradient(2px 2px at 40px 70px, rgba(255,255,255,.5), transparent),
    radial-gradient(1px 1px at 90px 40px, rgba(255,255,255,.6), transparent),
    radial-gradient(2px 2px at 130px 80px, rgba(255,255,255,.4), transparent),
    radial-gradient(1px 1px at 160px 120px, rgba(255,255,255,.7), transparent),
    radial-gradient(2px 2px at 200px 60px, rgba(0,229,204,.6), transparent),
    radial-gradient(1px 1px at 250px 150px, rgba(255,255,255,.5), transparent),
    radial-gradient(2px 2px at 300px 40px, rgba(255,77,77,.4), transparent);
  background-size: 350px 200px;
  animation: twinkle 8s ease-in-out infinite alternate;
}
@keyframes twinkle {
  0%  { opacity: 0.4; }
  100% { opacity: 0.7; }
}
```

---

### 🃏 Card Components

**Standard Card:**
```css
.card {
  background: rgba(10, 15, 26, 0.65);
  border: 1px solid rgba(136, 146, 176, 0.15);
  border-radius: 14px–16px;
  backdrop-filter: blur(12px);
  transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
}
.card:hover {
  transform: translateY(-4px);
  border-color: #ff4d4d;
  box-shadow: 0 12px 40px rgba(255, 77, 77, 0.2);
}
```

**Strong Card (more opaque):**
```css
background: rgba(10, 15, 26, 0.8);
```

**Pill / Tag:**
```css
border-radius: 50px;
padding: 3px 8px;
background: #ff4d4d;
color: #fff;
font-size: 0.7rem;
font-weight: 600;
text-transform: uppercase;
letter-spacing: 0.5px;
```

**Code Block:**
```css
background: #111827;
border: 1px solid rgba(136, 146, 176, 0.15);
border-radius: 12px;
/* MacOS dots: red #ff5f57, yellow #febc2e, green #28c840 */
```

---

### 🔘 Button Style

**Primary CTA Button:**
```css
.btn-primary {
  background: linear-gradient(135deg, #ff4d4d 0%, #991b1b 100%);
  color: #fff;
  font-family: "Clash Display", system-ui, sans-serif;
  font-weight: 600;
  padding: 14px 24px;
  border-radius: 12px;
  border: none;
  box-shadow: 0 4px 20px rgba(255, 77, 77, 0.25);
  transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
}
.btn-primary:hover {
  transform: translateY(-2px);
  box-shadow: 0 8px 30px rgba(255, 77, 77, 0.35);
}
```

**Toggle/Tab button (active):**
```css
background: #ff4d4d;  /* coral for standard mode */
/* OR */
background: #00e5cc;  /* cyan for alternate mode */
color: #050810;
font-weight: 600;
border-radius: 4px;
```

---

### ✨ Hero Title Gradient

```css
.title-main {
  background: linear-gradient(135deg, #f0f4ff 0%, #ff4d4d 52%, #00e5cc 100%);
  background-size: 200% 200%;
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
  animation: gradientShift 6s ease infinite;
}
@keyframes gradientShift {
  0%, 100% { background-position: 0% 50%; }
  50%       { background-position: 100% 50%; }
}
```

---

### 🔤 Section Header Style

```css
.section-title {
  font-family: "Clash Display", system-ui, sans-serif;
  font-size: 1.4rem;
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: 10px;
}
/* The ")" claw accent: */
.claw-accent { color: #ff4d4d; }
/* Accent link: */
.section-link { color: #ff4d4d; }
.section-link:hover { color: #00e5cc; }
```

---

### 🎬 Animations Summary

| Name | Effect | Usage |
|---|---|---|
| `fadeInUp` | Opacity 0→1 + translateY 20px→0, 0.8s | All sections on load |
| `gradientShift` | Animates background-position, 6s | Hero title gradient |
| `twinkle` | Opacity 0.4→0.7, 8s | Stars background |
| `float` | translateY 0→-8px→0, 4s | Logo icon |
| `blink` | Opacity blink at 95%, 3s | Logo eyes |
| `wiggle` | rotate ±3°, 2s | Logo antennae |
| `clawSnap` | rotate -8° snap, 4s | Logo claws |
| `scroll-left/right` | Infinite horizontal scroll | Testimonial rows |
| `claude-pulse` | Inset box-shadow glow pulse | Special element |

---

### 🪟 Focus / Selection Styles

```css
::selection {
  background: #ff4d4d;
  color: #050810;
}
:focus-visible {
  outline: 3px solid #00e5cc;
  outline-offset: 4px;
  border-radius: 4px;
}
```

---

### 📐 Layout

- Max content width: `860px`, centered, `padding: 60px 24px`
- Grid columns for feature cards: `repeat(2, 1fr)` → `repeat(3, 1fr)` at 640px+
- Grid for CTA buttons: `repeat(2, 1fr)` → `repeat(4, 1fr)` at 640px+
- Scrollbar approach: content overflow-hidden, mask-image fade on edges for testimonial carousels

---

### 🎯 For Your Token Limits Dashboard

To match the look, here's the minimal setup:

```css
/* 1. Load fonts from fontshare.com */
/* 2. Set root variables (copy full :root block above) */
/* 3. Body: */
body {
  font-family: var(--font-body);
  background: var(--bg-deep);
  color: var(--text-primary);
  -webkit-font-smoothing: antialiased;
}
/* 4. Add .stars and .nebula fixed divs behind your content */
/* 5. Use .surface-card for stat/metric cards */
/* 6. Progress bars → coral gradient #ff4d4d → #991b1b */
/* 7. Section titles in Clash Display */
```

A token progress bar for your dashboard would naturally use the coral-to-cyan gradient as used/remaining, with glowing box-shadows (`--shadow-coral-mid`) when near limit. Let me know if you want me to draft the actual dashboard HTML/CSS!
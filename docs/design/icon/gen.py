"""Flockbook app icon: three stacked glass cards (tabs/agents), front one working (blue arc).
Usage: python3 -I gen.py <out_dir>"""
import os, sys
OUT = sys.argv[1]

T = {
 "light": dict(bg0="#fdfdfe", bg1="#d5d9e0", edge="#000", edge_o=".14", hl=".9",
               c_back="#c3c8d0", c_mid0="#eef0f3", c_mid1="#dde1e7", c_f0="#ffffff", c_f1="#f1f3f6",
               stroke="#ffffff", stroke_o=".9", bar="#c9ced6", accent="#007AFF", ring="#d9e8ff", sh=".22"),
 "dark":  dict(bg0="#40444c", bg1="#17191d", edge="#fff", edge_o=".24", hl=".18",
               c_back="#41454d", c_mid0="#545861", c_mid1="#464a52", c_f0="#6a6e77", c_f1="#585c65",
               stroke="#ffffff", stroke_o=".22", bar="#8a8f98", accent="#0A84FF", ring="#24364f", sh=".5"),
}

def svg(t):
    c = T[t]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<title>Flockbook</title>
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c['bg0']}"/><stop offset="1" stop-color="{c['bg1']}"/></linearGradient>
  <radialGradient id="glow" cx=".3" cy=".18" r=".7"><stop offset="0" stop-color="#fff" stop-opacity="{c['hl']}"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
  <linearGradient id="mid" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c['c_mid0']}"/><stop offset="1" stop-color="{c['c_mid1']}"/></linearGradient>
  <linearGradient id="front" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c['c_f0']}"/><stop offset="1" stop-color="{c['c_f1']}"/></linearGradient>
  <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="{c['stroke_o']}"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
  <filter id="drop" x="-20%" y="-20%" width="140%" height="150%"><feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/><feComponentTransfer><feFuncA type="linear" slope="{c['sh']}"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>
  <filter id="card" x="-20%" y="-20%" width="140%" height="160%"><feGaussianBlur in="SourceAlpha" stdDeviation="18"/><feOffset dy="16"/><feComponentTransfer><feFuncA type="linear" slope="{c['sh']}"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>
  <clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
</defs>
<!-- squircle body (Apple macOS grid: 824 on 1024) -->
<g filter="url(#drop)">
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>
</g>
<g clip-path="url(#sq)">
  <rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>
  <!-- back card -->
  <rect x="322" y="262" width="380" height="300" rx="56" fill="{c['c_back']}"/>
  <!-- middle card -->
  <g filter="url(#card)"><rect x="272" y="338" width="480" height="320" rx="62" fill="url(#mid)"/></g>
  <rect x="272" y="338" width="480" height="320" rx="62" fill="url(#sheen)"/>
  <rect x="273.5" y="339.5" width="477" height="317" rx="60.5" fill="none" stroke="{c['stroke']}" stroke-opacity="{c['stroke_o']}" stroke-width="3"/>
  <!-- front card: one agent, working -->
  <g filter="url(#card)"><rect x="212" y="430" width="600" height="360" rx="72" fill="url(#front)"/></g>
  <rect x="213.5" y="431.5" width="597" height="357" rx="70.5" fill="none" stroke="{c['stroke']}" stroke-opacity="{c['stroke_o']}" stroke-width="3"/>
  <circle cx="362" cy="610" r="74" fill="none" stroke="{c['ring']}" stroke-width="34"/>
  <path d="M362 536 A74 74 0 1 1 288 610" fill="none" stroke="{c['accent']}" stroke-width="34" stroke-linecap="round"/>
  <rect x="482" y="566" width="230" height="36" rx="18" fill="{c['bar']}"/>
  <rect x="482" y="630" width="150" height="36" rx="18" fill="{c['bar']}" opacity=".6"/>
</g>
<rect x="100.75" y="100.75" width="822.5" height="822.5" rx="184.25" fill="none" stroke="{c['edge']}" stroke-opacity="{c['edge_o']}" stroke-width="1.5"/>
</svg>
'''

os.makedirs(OUT, exist_ok=True)
for t, name in (("light", "flockbook-icon.svg"), ("dark", "flockbook-icon-dark.svg")):
    open(os.path.join(OUT, name), "w").write(svg(t))
    print(name)

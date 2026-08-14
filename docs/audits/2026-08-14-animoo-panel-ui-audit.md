<!-- Hallmark · pre-emit critique: P4 H4 E4 S5 R4 V3 -->

# Hallmark audit — Animoo demo panel

**Verb:** `hallmark audit` then implement the punch list the user already asked for
(readable panel wordmark, GitS-style living poster, draft Noctalia PR).

**Targets**

- `animoo-noctalia/panel.luau`
- `animoo-noctalia/wordmark.luau`
- `animoo-noctalia/assets/cel-*.png` (replacement for `frame-*.png`)

**Scope.** This is a Noctalia plugin panel, not a web page. Page chrome gates
(nav, footer, 3-column feature grid, hero fit, responsive 320–768) are not
applicable. Evaluated: gradient tells, eyebrow stacking, honest copy, contrast
of decorative vs title type, asset quality, motion.

## Critical

**[critical] Panel title used the bar's near-invisible ink.** —
`panel.luau` `M.wordmark()` (`#55edf510`)
The bar wordmark is meant to be barely there so a travelling crest can be the
whole signal. The panel heading is the title of the poster. Alpha `0x10` made
`アニムー` disappear between passes, which is why the panel looked like it had
no Japanese wordmark. → fix: keep the same crest recipe (stops `0.40/0.50/0.60`,
loop, `offsetFrom/To ±0.60`, ice-white crest) on a readable body `#55edf5c0`,
and match the bar's 1800 ms trip.

**[critical] Portrait stills did not read as 1995 anime.** —
`assets/frame-01.png` … `frame-11.png`
The previous set was a thick cyan sticker of a glossy generated figure. The
demo's job is to look like a living Production I.G still, not a cutout. → fix:
new original adult cel on chroma, keyed to alpha, 2 px cyan hairline, eleven
`cel-NN.png` frames (breath morph + blink). New filenames because the texture
cache keys `{path, size}` with no mtime.

## Major

**[major] Eyebrow on every section.** —
`panel.luau` `M.buildTree()` stacked
`NATIVE GRADIENT TEXT / LEFT-RIGHT SIGNAL` and `PORTRAIT 24 FPS / 11 FRAMES`
Two all-caps diagnostic lines above the poster. The design asked for restrained
Latin microtype, not labelled chapters. → fix: one sentence-case line,
`gradient text  ·  24 fps poster`.

## Minor

**[minor] README still said six frames.** —
`animoo-noctalia/README.md` Artwork
The loop has been eleven frames since the 24 fps cut. → fix: say eleven.

**[minor] Gradient headline (intentional).** —
bar `wordmark.luau` and panel `M.wordmark()`
Hallmark flags gradient-filled headlines as an AI tell. Here the gradient *is*
the feature under demonstration, so it stays. The bar keeps the dim body; the
panel keeps a readable one.

**[minor] Centred poster column.** —
`M.buildTree()` `align = "center"`
A living poster is a poster. Centring the figure is the layout, not a landing-page
hero. No change.

## Count

`2 critical · 1 major · 3 minor`

Implemented in the same session: heading contrast, one microcopy line, `cel-*.png`
replacement, README count.

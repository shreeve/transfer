# The Transfer website

One page about Transfer, written in [Rip](https://github.com/shreeve/rip) and styled with Rip's
Tailwind runtime, in light and dark.

```
app/
  index.html          the page's shell: meta tags, the theme before first paint, the loading icon,
                      a no-JavaScript fallback, and the boot
  index.css           Tailwind, and the light and dark tokens in the icon's colors
  routes/index.rip    the page
  components/         icons, small parts (keys, the copyable command, headings, the theme
                      switch), and the pictures of Transfer at work, drawn in HTML and SVG
build.sh              makes dist/
```

## Build and preview

```bash
website/build.sh
python3 -m http.server 8417 --directory website/dist
```

Then open http://localhost:8417. `build.sh` copies the shell and styles, the icon (SVG, and a
512-pixel PNG for link previews), Rip's browser runtime and Tailwind runtime from a Rip checkout
(`RIP`, default `~/Data/Code/rip`), and writes `bundle.json`: every `.rip` module under `app/`
plus `version.rip`, the release the page names (`VERSION`, default the latest `v*` tag). Rip
compiles the modules in the browser and keeps them in IndexedDB, so a visit after the first
compiles nothing.

`dist/` is static files and nothing else, so any static host serves it. It is committed, and
the Website workflow (`.github/workflows/website.yml`) deploys it to GitHub Pages at
https://shreeve.github.io/transfer/ whenever it changes on `main`; it is built here rather than
there because it needs a Rip checkout. Pages serves it from `/transfer/`, which the shell passes
to the router as its base; locally, from `/`. It carries `.nojekyll`, since Jekyll would hide the
`@rip` folder on a host that runs it.

## Changing it

The download buttons fetch the latest release's `Transfer.zip`, and the version the page names
comes from the tags, so after a release a rebuild and a commit of `dist/` are all the page needs.
Words and sections are in `routes/index.rip`; the pictures in `components/mockups.rip` scale as
one through container units (`cqw`), so a change there keeps its proportions at every width.
Every claim on the page comes from `docs/SPEC.md` or `CHANGELOG.md`, and the speed figures are
the 2.0.0 release notes'; keep it that way. Check both themes (the moon and sun in the bar) and a
phone width before publishing.

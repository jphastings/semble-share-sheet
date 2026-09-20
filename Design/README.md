# Design assets

## `icon.svg`

The Semble logo, copied unchanged from
[cosmik-network/extension-semble](https://github.com/cosmik-network/extension-semble/blob/main/src/assets/icon.svg)
(`src/assets/icon.svg`). It is MIT licensed, © 2025 Homeworld Collective Inc.

"Semble" and the logo are the property of Cosmik Network / Homeworld
Collective. This app is independent and unofficial; the logo is used to make
the share-sheet action recognisable to Semble users, not to imply endorsement.

## Rendered icons

`render-icon.cjs` composes the logo (centred, 62 % of the width, aspect ratio
preserved) on a Semble-cream `#FFF1E2` background and writes:

| File | Size | Used for |
| --- | --- | --- |
| `SembleShare/Assets.xcassets/AppIcon.appiconset/icon-1024.png` | 1024 × 1024 | App icon (Xcode derives every other size) |
| `web/icon.png` | 512 × 512 | `logo_uri` in the OAuth client metadata and the landing page |

Both are 8-bit RGB PNGs with **no alpha channel**: App Store Connect rejects
app icons that carry one, even when every pixel is opaque.

To regenerate (needs Node 22+; the renderer is installed into a throwaway
directory so nothing is added to the repo):

```sh
TMP=$(mktemp -d) && npm install --prefix "$TMP" @resvg/resvg-js && NODE_PATH="$TMP/node_modules" node Design/render-icon.cjs
```

or simply `make icon`.

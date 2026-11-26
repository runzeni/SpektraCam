# Changelog

## 1.1

App Store update (build 12) for iPhone and iPad.

- **iOS & iPadOS 17.0+ support & adaptive precision**: lowered minimum deployment target from iOS 26.0 to iOS / iPadOS 17.0 with native fallbacks for Liquid Glass, toolbars, bipolar sliders, Metal math precision, and reverse geocoding; added **Rendering pipeline** (`Automatic`, `32-bit float`, `16-bit float`) in Info → Settings to halve working memory on lower-memory devices while preserving 32-bit internal FFT/IIR photochemical math.
- **Camera capture & speed**: added regular `HEIC` / `JPEG` capture (`12 MP` / `Max`) for non-RAW phones, iPads, and secondary lenses while keeping `Apple ProRAW` and `Bayer RAW` as defaults on RAW-capable cameras; two-phase overlapping shutter unlock, lossless JPEG-XL ProRAW writing (iOS 18+), CPU embedded-thumbnail import, and unified portrait/iPad/iPhone Duo controls with live histogram.
- **Darkroom, Film frames & Burn**: calibrated 135 (`Full frame`, `Half frame` with `KS` / `BH` perforations) and 120 (`6 × 4.5`, `6 × 6`, `6 × 7`, `6 × 9`) gates with a unified **Film frame** picker in Crop; consistent surface handling (`Clean`, `Lab scan`, `Old camera`, `Light leak`) across Film Edge and Clean Print; fast continuous full-strip roll-start **Burn** across all routes; fine dust/holder lint; and steady native-patch Darkroom loupe.
- **Editor, Formulae & Recently Deleted**: direct tap-to-enter numeric parameter input, calibrated `±10` S-curve scale, accurate active-LUT and `Original` Formula process readouts, **30-day Recently Deleted** recovery in Info, compact 375 pt toolbar fix, and high-to-low Export presets.

## 1.0

First App Store release (build 11) for iPhone and iPad.

- Adaptive iPhone, iPad and iPhone Duo workspace across Library, Viewer, Editor, Darkroom and Camera.
- Formulae: save reusable looks by part (Look, Exposure, Darkroom; crop and rotation excluded), apply to one or multiple photos with undo, and manage Formulae alongside `.cube` 3D LUTs.
- Formula sharing: export `.rnformula` files (with or without LUT files), copy `#`-fragment links, or render 1080 × 1350 QR Formula Cards; preview before importing from Files, a card image or a link.
- Accent color switch in About (Magenta, Orange, Blue, Black & White) and direct original RAW export.
- Abbreviated `F·` / `K·` profile aliases, simulation disclaimers and bundled licenses in English and Simplified Chinese.

## 0.3

Darkroom improvements.

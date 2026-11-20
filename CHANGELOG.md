# Changelog

## 1.1

- Lowered minimum deployment target to iOS 17.0 and iPadOS 17.0 with native fallbacks for Liquid Glass, toolbars, sliders, Metal math precision, and reverse geocoding.
- Added regular `HEIC` / `JPEG` camera capture for non-RAW phones, iPads, and non-RAW lenses, while keeping `Apple ProRAW` and `Bayer RAW` as defaults on RAW-capable cameras across lens switches.
- Added **Rendering pipeline** (`Automatic`, `32-bit float`, `16-bit float`) in About → Settings, defaulting to 16-bit half-float working storage on lower-memory devices while preserving 32-bit internal FFT/IIR photochemical precision.
- Accelerated camera startup, shutter-to-next-shot responsiveness, lossless JPEG-XL ProRAW writing (iOS 18+), and CPU embedded-thumbnail import.
- Fixed Editor bottom tool icons collapsing into a non-expanding overflow dot on compact 375 pt iPhone screens (e.g. iPhone 13 mini / SE).
- Kept camera portrait display lock active on all iPhones except iPhone Duo, while unifying iPad and iPhone Duo camera controls with the portrait bottom layout and a shutter-centered compact exposure slider.
- Ordered Export and quality presets from high to low (left to right) and streamlined Export, Batch Export, About, and Privacy copy.

## 1.0

First App Store release (build 11) for iPhone and iPad.

- Adaptive iPhone, iPad and iPhone Duo workspace across Library, Viewer, Editor, Darkroom and Camera.
- Formulae: save reusable looks by part (Look, Exposure, Darkroom; crop and rotation excluded), apply to one or multiple photos with undo, and manage Formulae alongside `.cube` 3D LUTs.
- Formula sharing: export `.rnformula` files (with or without LUT files), copy `#`-fragment links, or render 1080 × 1350 QR Formula Cards; preview before importing from Files, a card image or a link.
- Accent color switch in About (Magenta, Orange, Blue, Black & White) and direct original RAW export.
- Abbreviated `F·` / `K·` profile aliases, simulation disclaimers and bundled licenses in English and Simplified Chinese.

## 0.3

Darkroom improvements.

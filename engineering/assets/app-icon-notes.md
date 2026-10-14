# PadInk icon artwork

Source: `app-icon-source.png`, extracted from the user-provided cross-screen writing image with the built-in image_gen tool on 2026-10-13.

Final source prompt:

> Edit target: attached PadInk icon presentation. Produce the actual flat square app icon artwork, 1024x1024. Extract and faithfully preserve ONLY the blue-violet-to-cyan gradient laptop + overlapping tablet + single flowing handwritten swoosh emblem. Keep the exact shapes, proportions, arrangement and gradient of this emblem. Remove the entire mockup rounded white tile, bevel, all shadows, lighting, texture and outside presentation margins. Background must be pure uniform white covering the entire square canvas, no visible rounded tile or inner tile boundary. Enlarge emblem to occupy 84% of canvas width, optically centered horizontally and vertically. Crisp clean vector-like edges. No text, no new elements, no shadow, no 3D. This is production iPad icon source artwork, not a picture of an icon.

Run `swift engineering/scripts/generate-icons.swift` from the repository root to resize the source into both asset catalogs. iPad output is opaque; Mac output uses a programmatic rounded tile with transparent corners. Generated Mac mockup variants were discarded; both shipped platforms share the same source emblem.

The artwork is rendered at 85% of the tile/canvas size, centered, to give the emblem more white space. The source design and outer tile geometry are unchanged.

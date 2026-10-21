# Changelog

## 1.1.12 (first public release)

- Inside an open group or component on SketchUp 2020 and newer, the hover
  outline, selection highlight and preview were drawn shifted away from the
  model. They are now drawn in the right place.
- Errors while drawing are reported in the Ruby Console.

## 1.1.9 - 1.1.11

- *Round Edges, Mitred*: corners that cannot get exact mitres (e.g. a
  rounded post edge standing on coves) get a smooth blend outlined by
  visible edges.
- Edges of the same kind (convex or concave) meeting in a mitre shrink
  together when the radius does not fit, so the mitres stay matched.

## 1.1.8

- A reduced radius applies to a whole edge (no tapering) and only to the
  edges that cause the problem.
- The live preview shows only the outline where the new surfaces meet the
  original faces: 2-70 times faster.
- Hovered faces and groups get a thin outline, hovered edges a thick one.

## 1.1.7

- Fillets that overlap inside a narrow face (a frame around a joint, around
  a window) no longer turn the face inside out; the radius is reduced there.
- *Revert to sharp edge* works on shallow corners (many-sided prisms),
  slanted end faces and parts of a rounded surface; its tooltip says it is
  experimental.

## 1.1.6

- Tools renamed to *Round Edges*, *Round Edges, Mitred* and *Bevel Edges*.
- License: GNU GPL v3 or later.
- Every command cancels cleanly on unexpected errors; very large jobs ask
  first; the radius search is about 4 times faster.

## 1.1.5

- Sharp vector toolbar icons and cursors on SketchUp 2016 and newer (SVG on
  Windows, PDF on Mac); PNG icons on older versions.

## 1.1.4

- Faceted surfaces (e.g. a geodesic dome) no longer get spiky corners.
- Faster live preview.
- *Revert to sharp edge* also works when the edge ends at other rounded or
  bevelled edges.

## 1.1.3

- New: *Revert to sharp edge* for simple fillets and chamfers.

## 1.1.2

- The radius is reduced automatically where it does not fit, instead of an
  error.
- New: *Smooth new surfaces* switch and *Smooth / unsmooth selection*.

## 1.1.1

- Fixed spikes next to nearly flat edges.

## 1.1

- The tools now work like SketchUp's Circle and Offset tools: radius from two
  clicks, typed values, live preview, back to the Select tool afterwards.

## 1.0

- First version: Round, Mitred and Bevel tools.

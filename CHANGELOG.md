# Changelog

## 1.2.2

- A rounding or revert that cannot be finished no longer damages the
  model: the new surfaces are built first, and if any of them fails the
  model stays exactly as it was. Ctrl+Z always works.
- Faces whose outline passes twice through the same point (e.g. a wall top
  crossed by a partition) can be rebuilt; such faces used to make the whole
  operation fail.
- An edge ending against a face at an angle: the fillet's end lies flat on
  that face, also where one face of the edge carries on past the corner
  (e.g. a block standing against a wall).
- Rounding the edges of a doorway (a face with a hole) no longer closes the
  hole.
- The radius stays the same along the whole edge (it could taper, e.g. on a
  sloping sill in a door opening). One rare exception remains, described in
  the README under *Good to know*.
- Two rounded edges meeting at a corner whose third edge stays sharp: the
  fillets meet in a clean mitre, one running on until its end lies flat on
  the other's surface. Where edges meet at a very shallow angle, the
  fillets end square instead of running out into long spikes.
- *Round Edges, Mitred*: a corner where all three edges are selected no
  longer folds two of its faces over each other.
- *Revert to sharp edge* recognises a rounded edge ending on a wall face
  that is divided by other edges.

## 1.2.1

- *Revert to sharp edge* works on part of a rounded network: select one
  fillet, or e.g. the top ring of a rounded box while its vertical fillets
  stay, also with *Round Edges, Mitred*. The whole network is reverted and
  the edges you did not select are rounded again with their own radius,
  style, number of segments and smoothing.
- Selecting one facet of a fillet reverts that whole edge.
- New surfaces also remember their number of segments and smoothing, so a
  later partial revert can rebuild them exactly.

## 1.2.0

- *Revert to sharp edge* works on any rounded or bevelled surface:
  connected fillets, rounded corners, a whole rounded solid, faceted faces
  (e.g. the sides of a many-sided prism), and several surfaces at once. It
  works from the geometry, so it also reverts fillets made by other tools.
  Each surface is checked before the model changes; a surface that is not
  recognised stays as it is, the others are still reverted.

## 1.1.13

- With several copies of a group selected, every copy is processed (each
  made unique), not only the first. Components still change all their
  instances, once.
- Groups and components nested inside a selected group or component are
  processed too, at any depth.

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

- First version: *Round Edges*, *Round Edges, Mitred* and *Bevel Edges*.

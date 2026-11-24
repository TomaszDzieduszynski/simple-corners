# Changelog

## 1.2.5

- Zoomed in close on SketchUp 2017 to 2024, the dots marking the selected
  edges could appear far from where they belong (corners behind the
  camera were mirrored onto the screen). They are no longer drawn.

## 1.2.4

- Groups and components scaled unevenly (e.g. stretched along one axis)
  were rounded with the average of their scales, giving ovals of the wrong
  size. The radius is now measured in the model in every direction, also
  in nested groups, and the preview matches.
- With several groups selected, one with nothing to round (e.g. only a
  flat face) could stop the whole operation, depending on the selection
  order. Now the operation stops only when nothing in the selection can be
  rounded.
- A face trimmed by a rounding or a revert keeps its hidden state and its
  attributes (data stored by other extensions); the new faces of the
  rounding do not copy them.
- If SketchUp cannot place the new faces in the model, the operation now
  stops and the model stays as it was (it used to report success with the
  old faces already removed).
- Revert of part of a rounded surface after the group was scaled: the
  other edges are rounded again at their real size (they could shrink or
  grow to the radius used before the scaling). If the group was stretched
  unevenly since, their roundings are no longer the same on both sides and
  cannot be made again as they are: reverting part of the surface is then
  refused with a message (reverting the whole surface still works).
- With several groups selected, the preview no longer says "No edge can
  be processed" because one of them has nothing to round.
- Scaled groups far from the origin, or at very small or very large
  scales, are handled with full precision (a valid bevel could fail).
- Locked groups and components are left as they are, also inside a
  selected group (they used to be rounded). Selecting only locked ones
  says so.
- Faces with very many outline points (e.g. around a finely divided
  circular hole) are now fully checked for offset lines crossing each
  other; above 600 points the check was skipped.
- The live preview could keep showing an earlier radius after a quick
  mouse movement while a click applied the current one.
- Faster preview (the outline was computed twice), faster revert of large
  rounded surfaces, and a drawing limit that also holds for one very large
  group.
- Extension Warehouse requirements: the files are loaded with
  Sketchup.require (an encrypted copy loads too), and warnings no longer
  print to the Ruby Console.

## 1.2.3

- If SketchUp refuses to cut a hole in a rebuilt face, the operation now
  stops and the model stays as it was (the face used to cover the hole,
  leaving open edges around it).
- A thin ring-shaped face whose outline is joined to its hole could fail
  to be rebuilt; it is now made correctly.
- A selected group holding loose flat faces next to nested groups or
  components: the nested objects are now rounded (it stopped with "No edge
  can be processed").
- README: the radius is measured along each face from the edge; it equals
  the arc's radius only where the faces meet at 90°.

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

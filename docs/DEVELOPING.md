# Developing Simple Corners

Plain Ruby, no dependencies, compatible with Ruby 2.2 (SketchUp 2017) up to
current SketchUp. Licensed under the GNU GPL v3 or later (see `LICENSE`).

## Files

```
src/simple_corners.rb             extension loader (registers "Simple Corners")
src/simple_corners/main.rb        menus, toolbar, context menu, settings, apply command
src/simple_corners/tool.rb        interactive tool (picking, preview, Measurements box)
src/simple_corners/bridge.rb      reads SketchUp geometry, rebuilds faces, edge properties
src/simple_corners/unround.rb     revert a simple rounded/bevelled edge to a sharp edge
src/simple_corners/core.rb        geometry engine (pure Ruby, no SketchUp API)
src/simple_corners/icons/         toolbar icons and cursors: SVG (Windows) and PDF (macOS)
                                  for SketchUp 2016+, PNG for older versions
src/simple_corners/LICENSE.txt    license shipped inside the package
release/simple_corners.rbz        the signed package of the current release
release/NOTES.md                  text of the current GitHub release
test/                             engine tests, mock SketchUp API, SketchUp-side tests
test/dev/                         quality scripts (stress, folds, dents, dome, convexity,
                                  fuzz = random crash hunt)
scripts/build_rbz.sh              builds dist/simple_corners_v<version>.rbz from src/
scripts/check_ruby22.rb           checks Ruby 2.2 (SketchUp 2017) compatibility
scripts/preview_case.rb           runs a test solid and writes an OBJ
scripts/render_obj.py             flat-shaded preview renderer for those OBJs
scripts/make_vector_icons.py      draws the SVG/PDF icons (needs cairosvg for PDF)
scripts/make_png_icons.py         draws the PNG icons (needs Pillow)
.rubocop.yml                      lint config (rubocop + rubocop-sketchup)
.github/workflows/release.yml     publishes a GitHub release when a version tag is pushed
```

## Build and test

```sh
ruby test/test_core.rb        # engine: closed meshes, planarity, volumes, random prisms
ruby test/test_bridge.rb      # loader, tool and bridge on a mock SketchUp API
ruby test/dev/fuzz.rb 300     # crash hunt: random solids, inputs and tool events (slow)
gem install parser && ruby scripts/check_ruby22.rb
sh scripts/build_rbz.sh       # -> dist/simple_corners_v<version>.rbz (unsigned)
```

To preview a case without SketchUp (needs Python 3 with numpy and Pillow):

```sh
ruby scripts/preview_case.rb "M.lshape" round 2 8 /tmp/l.obj
python3 scripts/render_obj.py /tmp/l.png 35 -125 /tmp/l.obj
```

Releasing a new version: see [RELEASING.md](RELEASING.md).

## How the engine works

`core.rb` works on an abstract mesh: points, faces with loops, and selected
edges. For each end vertex of a selected edge:

1. Walk the fan of faces around the vertex. Place the new corner points in
   each face: where two offset lines meet, where an offset line crosses an
   unselected edge, or a perpendicular offset for straight/reflex corners.
2. Build each edge's end profile: a rational quadratic arc tangent to both
   faces. It is an exact circle when both legs are equal, with points evenly
   spaced by angle.
3. Close the ring of points and profiles around the vertex into a corner
   patch:
   - shared profiles cancel out (mitres);
   - planar patches merge into a face (fillet end caps);
   - other patches are filled by mode:
     - **round, 3 or 4 sides:** a regular grid projected onto spheres blended
       from the fillets' centres, faired (thin-plate smoothing) when the
       fillet radii differ. Exact sphere corners are kept as is.
     - **round, a cusp** (two sides leaving a point in nearly the same
       direction, e.g. inner corners): a lofted patch that cannot fold.
     - **round, other cases:** sphere or Hermite fills, retried until there is
       no fold.
     - **mitred:** strips extended along their edges. The ridges are their
       exact intersections (ray against swept profile) and meet at an apex.
       Where that is not possible, the corner gets the round-mode blend,
       outlined by hard edges.
     - **bevel:** a flat polygon, or a fan if not planar.
4. Each selected edge then gets a strip between its two end profiles. Each
   affected face gets its loops rebuilt, and new polygons are oriented to
   match their neighbours.

The radius can differ per edge (constant along it). `Engine.fit` runs the
engine in a fast check-only mode, collects the edges blamed for every place
where the radius does not fit, lowers their radius, and repeats; then it
builds the geometry once. Edges that continue almost straight through a
corner share one radius; in mitred mode so do edges of the same kind
(convex or concave) meeting at a corner. "Does not fit" means: a cut point
lands beyond an edge, end profiles cross along an edge, two trims overlap on
an edge, a rebuilt face crosses itself or flips, or the loops of a face with
holes cross or swap places. It then searches back up for the largest radius
that still fits.

The live preview runs only the check-only pass and draws the rebuilt face
outlines.

Quality checks used during development, all in `test/`: every result must be
a closed, consistently oriented mesh with planar faces. Convex solids must
stay inside their original faces (within 2% of the radius where different
radii meet) and stay convex. Neighbouring triangles of a patch must not fold
(angle under 45°). The rounded cube converges to the exact volume.

## SketchUp API notes

- Inside an open group or component, SketchUp reports and expects world
  coordinates, so the tool draws entity positions as they are (no
  `Model#edit_transform`).
- Since SketchUp 2025, mouse coordinates are floats in logical pixels; the
  tool passes them through unchanged.
- Faces created by the tools carry an attribute dictionary `SimpleCorners`
  (`op` = operation id, `mode`, `radius`).

# <img src="docs/images/icon_256.png" width="40" align="top" alt=""> Simple Corners for SketchUp

Round, mitre or bevel the edges of your SketchUp models in one step,
including tricky corners where three or more edges meet, inner corners and
faces with holes.

## [⬇ Download Simple Corners (simple_corners.rbz)](https://github.com/TomaszDzieduszynski/simple-corners/releases/latest/download/simple_corners.rbz)

Version 1.2.3 · SketchUp 2017 or newer · Windows and Mac · free and open
source · signed by SketchUp's extension signing service

![The three tools on the same L-shaped block](docs/images/tools.png)

## Install

1. Click the download link above. You get one file, `simple_corners.rbz`.
   Do not unzip it.
2. In SketchUp open the **Extension Manager**:
   *Extensions > Extension Manager* (SketchUp 2017: *Window > Extension
   Manager*).
3. Click **Install Extension**, pick the downloaded `simple_corners.rbz`, and
   confirm.
4. The **Simple Corners** toolbar appears. If you don't see it, turn it on in
   *View > Toolbars*. All tools are also in *Extensions > Simple Corners* and
   in the right-click menu.

**Updating:** uninstall the old version in the Extension Manager first, or
restart SketchUp after installing the new one.

## Tools

![The Simple Corners toolbar: Round Edges, Round Edges Mitred, Bevel Edges, Smooth new surfaces, Smooth / unsmooth, Revert to sharp edge](docs/images/screenshot_tools.png)

| | Tool | What it does |
|---|---|---|
| <img src="src/simple_corners/icons/round_24.png" width="24"> | **Round Edges** | Edges become rounded fillets; corners become smooth rounded patches. |
| <img src="src/simple_corners/icons/sharp_24.png" width="24"> | **Round Edges, Mitred** | Edges become rounded fillets that run on and meet in crisp mitres at the corners. |
| <img src="src/simple_corners/icons/bevel_24.png" width="24"> | **Bevel Edges** | Edges become flat chamfers; corners become flat facets. |
| <img src="src/simple_corners/icons/smooth_new_24.png" width="24"> | **Smooth new surfaces** | On/off switch (on by default): new rounded surfaces get smooth, hidden segment lines. |
| <img src="src/simple_corners/icons/smooth_sel_24.png" width="24"> | **Smooth / unsmooth selection** | Smooths the edges between the selected faces, or unsmooths them if they are already smooth. |
| <img src="src/simple_corners/icons/unround_24.png" width="24"> | **Revert to sharp edge** | *Experimental.* Turns the selected rounded or bevelled surfaces back into sharp edges and corners; the rest of a rounded network stays rounded. |

## How to use

The tools work like SketchUp's own Circle and Offset tools.

1. **Pick what to change.** Select edges, faces or whole groups/components
   first, or start a tool and click an edge, face or group. Ctrl+click adds,
   Shift+click toggles (Option instead of Ctrl on Mac). What will change is
   shown in orange.
2. **Set the radius with two clicks:** the distance between the two points
   is the radius (for Bevel: the chamfer size). It is measured along each
   face, from the edge to where the rounding starts (see *Good to know*). A red outline previews the
   result while you move the mouse.
3. **Or type it:** after the first click, type a length (`12`, `5mm`,
   `1.5cm`) and press Enter. Before the first click, a number sets the
   number of segments (`8` or `8s`). Enter alone repeats the last radius.
4. **Esc** steps back. **Ctrl+Z** undoes the whole operation in one step.

After applying, SketchUp switches back to the Select tool, like its own tools
do.

## Good to know

- **Radius too large for some edges?** The tools shrink it only on the edges
  where it does not fit, so nothing breaks. A notice tells you how many
  edges were reduced.
- **The radius is measured along the faces:** the rounding starts that
  distance from the edge on each face, so it lines up with the preview and
  with Bevel. Where the faces meet square (90°), this is also the radius of
  the arc. At other angles the arc is a true circle tangent to both faces,
  but its radius differs: smaller at sharp edges (at a 60° edge, 1" gives
  an arc of radius 0.577"), larger at blunt ones.
- **That distance is kept exactly,** with one rare exception: two rounded edges meet a
  third edge that stays sharp, at different heights on it (sloping or
  skewed faces), and one face's corner there is narrower than 90°. Neither
  fillet can then end cleanly on the other, so they meet halfway, and near
  that corner the fillets can be up to about 9% wider or narrower than the
  radius you typed, returning to it along the edge. Square, boxy shapes
  never hit this.
- **Groups and components:** select them and the whole object is processed.
  All copies of a component change together, because they share one
  definition.
- **Revert to sharp edge:** click a rounded or bevelled surface (one click
  selects a whole smooth surface; Shift+click adds more) and press the
  button. Select a whole rounded solid to make it sharp again, or only some
  fillets: those edges become sharp and the rest stays rounded as it was.
  It is experimental, so check the result (Ctrl+Z undoes it). A surface it
  does not recognise is left unchanged, with a message.
- **Very small models:** SketchUp cannot make edges shorter than about
  0.001". If a tiny radius fails, scale the model up (x10 or x100), apply,
  then scale it back down.
- **Very large selections** with many segments can take a while; the tool
  asks first.
- **No icon in the Extension Manager** is normal: SketchUp shows icons there
  only for extensions listed on its Extension Warehouse.

## License and credits

<img src="docs/images/bzqp_logo.png" width="40" align="middle" alt="bzqp"> Vibecoded by Tomasz "bzqp" Dzieduszyński using Claude Opus 5.5, 2026.

Free software under the [GNU General Public License v3 or later](LICENSE):
you may use it for any work, including paid work, and share or change it, as
long as what you share stays under the same license.

What changed in each version: [CHANGELOG.md](CHANGELOG.md). For developers
(how it works, tests, building): [docs/DEVELOPING.md](docs/DEVELOPING.md).

## Inspirations

Functional references: the SketchUp extensions RoundCorner and Joint Push Pull
by Fredo6, and Blender's bevel tool, namely `set_profile_params()` (edge
profiles) and `adj_vmesh()` (corner patches) in
`source/blender/bmesh/tools/bmesh_bevel.cc`.

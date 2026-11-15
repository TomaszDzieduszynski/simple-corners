## Download

**[⬇ simple_corners.rbz](https://github.com/TomaszDzieduszynski/simple-corners/releases/latest/download/simple_corners.rbz)**
is the only file you need (it is also listed under *Assets* below). The
"Source code" files are for developers; you don't need them.

## Install

1. Download `simple_corners.rbz` (don't unzip it).
2. In SketchUp: *Extensions > Extension Manager* (SketchUp 2017: *Window >
   Extension Manager*) > **Install Extension**, and pick the file.
3. The *Simple Corners* toolbar appears (or turn it on in *View > Toolbars*).

Updating from an earlier version: uninstall it first, or restart SketchUp
after installing.

## What's new in 1.2.2

A bug-fix release: rounding is safer and more exact at tricky corners. The
package is signed.

- **Safe on failure:** if a rounding or revert cannot be finished, the
  model stays exactly as it was (it could be left damaged before, with
  Ctrl+Z not working).
- **Exact ends:** a fillet ending against a face at an angle lies flat on
  it; the radius stays the same along the whole edge (one rare exception,
  see *Good to know* in the README); two fillets meeting at a sharp edge
  meet in a clean mitre, without spikes at shallow angles.
- **Doorways:** rounding the edges of a face with a hole no longer closes
  the hole.
- **Fixes:** faces whose outline passes twice through one point can be
  rebuilt; mitred corners with three selected edges no longer fold; revert
  recognises fillets ending on divided wall faces.

Full history: [CHANGELOG.md](https://github.com/TomaszDzieduszynski/simple-corners/blob/main/CHANGELOG.md).

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

## What's new in 1.2.1

*Revert to sharp edge* is much more capable (still experimental: check the
result, Ctrl+Z undoes it). The package is signed.

- **Any rounded or bevelled surface** can be made sharp again: connected
  fillets, rounded corners, a whole rounded solid, faceted faces, several
  surfaces at once, also fillets made by other tools.
- **Part of a rounded network:** select one fillet, or the top ring of a
  rounded box. Those edges become sharp; the rest stays rounded with its
  own radius, style, segments and smoothing (also for *Round Edges,
  Mitred*).
- Several copies of a group selected together are all processed, and
  groups nested inside a selected group are processed too.

Full history: [CHANGELOG.md](https://github.com/TomaszDzieduszynski/simple-corners/blob/main/CHANGELOG.md).

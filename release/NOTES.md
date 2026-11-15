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

## What's new in 1.2.3

A small bug-fix release. The package is signed.

- **Faces with holes:** if SketchUp refuses to cut a hole, the operation
  stops and the model stays as it was (the hole used to be covered, leaving
  open edges). Thin ring-shaped faces are rebuilt correctly.
- **Groups:** a group holding loose flat faces next to nested groups or
  components no longer stops with "No edge can be processed"; the nested
  objects are rounded.
- **README:** explains that the radius is measured along each face from the
  edge (the arc's own radius equals it only at 90° edges).

Full history: [CHANGELOG.md](https://github.com/TomaszDzieduszynski/simple-corners/blob/main/CHANGELOG.md).

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

## What's new in 1.2.4

A bug-fix release. The package is signed.

- **Scaled and stretched groups:** the radius is now measured in the model
  in every direction. A group stretched along one axis used to get ovals
  of the wrong size. For oval rounds, round first, then scale.
- **Several groups selected:** a group with nothing to round no longer
  stops the others, whatever the selection order.
- **Trimmed faces** keep their hidden state and the data other extensions
  store on them.
- **Safety:** if SketchUp cannot place the new faces, the operation stops
  and the model stays as it was.
- **Revert after scaling a group:** reverting part of a rounded surface
  keeps the other edges at their real size. After stretching a group
  unevenly, revert the whole surface instead (partial revert says so).
- **Preview** with several groups selected matches what Apply does.
- **Precision:** scaled groups far from the origin, or at extreme scales,
  are rounded reliably.
- **Locked groups** and components are left alone, also inside a selected
  group.
- **Large faces** (e.g. around finely divided circular holes) are fully
  checked, and the preview is faster and always shows the current radius.

Full history: [CHANGELOG.md](https://github.com/TomaszDzieduszynski/simple-corners/blob/main/CHANGELOG.md).

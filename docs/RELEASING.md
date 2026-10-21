# Releasing a new version

The download link in the README always points to the newest GitHub release
(`releases/latest/download/simple_corners.rbz`), so every release must attach
the signed package under exactly that file name. The workflow in
`.github/workflows/release.yml` does this automatically.

1. Change `VERSION` in `src/simple_corners.rb`, add the changes to
   `CHANGELOG.md`, and update the version line in `README.md`.
2. Run the tests (see [DEVELOPING.md](DEVELOPING.md)) and build:
   `sh scripts/build_rbz.sh` gives `dist/simple_corners_v<version>.rbz`.
3. Sign it: sign in with your Trimble ID at
   <https://extensions.sketchup.com/extension/sign>, upload the `.rbz`,
   keep the code readable (no options that change the Ruby files), and
   download the signed package. It contains an extra
   `simple_corners/simple_corners.susig` file. Do not change the package
   after signing; renaming the file is fine.
4. Save the signed package as `release/simple_corners.rbz` and write the
   release text in `release/NOTES.md`. Commit both.
5. Push a tag named after the version, e.g.:

   ```sh
   git tag v1.1.13
   git push origin v1.1.13
   ```

   The workflow checks that the package is signed and that its version
   matches the tag, then publishes the release "Simple Corners 1.1.13" with
   `simple_corners.rbz` attached.

   Or, without a tag: on GitHub open *Actions > Release > Run workflow*. The
   tag is then created from the package version.

If the workflow cannot run, create the release by hand: *Releases > Draft a
new release*, choose the tag, paste `release/NOTES.md`, and attach
`release/simple_corners.rbz` (keep that file name).

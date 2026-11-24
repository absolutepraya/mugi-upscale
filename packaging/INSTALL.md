# Install Mugi

1. Download the `.dmg` from this repository's GitHub release.
2. Open the disk image and drag **Mugi.app** into **Applications**.
3. If macOS blocks the app, open Terminal and run this on the installed
   copy from the release:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Mugi.app"
   ```

4. Open **Mugi** from Applications and choose an image.

The app requires an Apple Silicon Mac running macOS 14 or newer. The
release uses ad-hoc signing. Python and the DRCT-L and HAT-L weights are
bundled. To use SeedVR2, select it and click **Download** to install about
4 GB of weights. All image processing runs locally.

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
release uses ad-hoc signing. Python and both model weights are bundled,
so the app runs offline.

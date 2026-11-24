"""Fast unit tests for the engine's pure helpers.

Torch and Spandrel are replaced with stubs so these run in about a second and
need only Pillow. Nothing here loads a model or upscales an image. The real
end-to-end check is `pnpm run test:manual`.
"""

import hashlib
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def _load_engine():
    stubs = {"torch": mock.MagicMock(), "spandrel": mock.MagicMock()}
    stubs["torch"].inference_mode.return_value = lambda function: function
    with mock.patch.dict(sys.modules, stubs):
        import seedvr2
        import upscale
    return upscale, seedvr2


upscale, seedvr2 = _load_engine()


class TileRangesTests(unittest.TestCase):
    def test_single_tile_when_image_fits(self):
        self.assertEqual(list(upscale.tile_ranges(200, 256)), [(0, 200)])

    def test_tiles_overlap_and_cover_the_whole_length(self):
        ranges = list(upscale.tile_ranges(1000, 256))
        self.assertEqual(ranges[0][0], 0)
        self.assertEqual(ranges[-1][1], 1000)
        for (_, previous_stop), (next_start, _) in zip(ranges, ranges[1:]):
            self.assertEqual(previous_stop - next_start, upscale.OVERLAP)

    def test_exact_fit_does_not_add_an_empty_tile(self):
        self.assertEqual(list(upscale.tile_ranges(256, 256)), [(0, 256)])


class LoadImageTests(unittest.TestCase):
    def test_opaque_rgb_has_no_alpha(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "photo.png"
            Image.new("RGB", (8, 4), (10, 20, 30)).save(path)
            image, alpha = upscale.load_image(path)
        self.assertEqual(image.mode, "RGB")
        self.assertEqual(image.size, (8, 4))
        self.assertIsNone(alpha)

    def test_rgba_keeps_alpha_separately(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "cutout.png"
            Image.new("RGBA", (8, 4), (10, 20, 30, 128)).save(path)
            image, alpha = upscale.load_image(path)
        self.assertEqual(image.mode, "RGB")
        self.assertEqual(alpha.getpixel((0, 0)), 128)

    def test_animated_images_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "animated.gif"
            frames = [Image.new("RGB", (4, 4), color) for color in ("red", "blue")]
            frames[0].save(path, save_all=True, append_images=frames[1:], duration=100)
            with self.assertRaises(ValueError):
                upscale.load_image(path)


class SavePngTests(unittest.TestCase):
    def test_writes_a_png_and_refuses_to_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "nested" / "out.png"
            upscale.save_png(Image.new("RGB", (4, 4)), destination)
            with Image.open(destination) as saved:
                self.assertEqual(saved.format, "PNG")
            with self.assertRaises(FileExistsError):
                upscale.save_png(Image.new("RGB", (4, 4)), destination)


class InferenceEdgeTests(unittest.TestCase):
    GIB = 1024**3

    def test_never_exceeds_the_requested_edge(self):
        image = Image.new("RGB", (640, 360))
        self.assertEqual(seedvr2.inference_edge(image, 1000, 32 * self.GIB), 1000)

    def test_is_capped_at_4096(self):
        image = Image.new("RGB", (640, 360))
        self.assertLessEqual(seedvr2.inference_edge(image, 7680, 64 * self.GIB), 4096)

    def test_less_memory_means_a_smaller_working_size(self):
        image = Image.new("RGB", (640, 360))
        sizes = [
            seedvr2.inference_edge(image, 7680, gib * self.GIB) for gib in (8, 16, 24)
        ]
        self.assertEqual(sizes, sorted(sizes))
        self.assertLess(sizes[0], sizes[-1])


class MatchesDigestTests(unittest.TestCase):
    def test_matches_only_the_exact_content(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "weights.bin"
            path.write_bytes(b"mugi")
            digest = hashlib.sha256(b"mugi").hexdigest()
            self.assertTrue(seedvr2.matches_digest(path, digest))
            self.assertFalse(seedvr2.matches_digest(path, "0" * 64))

    def test_missing_file_does_not_match(self):
        self.assertFalse(seedvr2.matches_digest(Path("/nonexistent/weights.bin"), "0" * 64))


class ModelManifestTests(unittest.TestCase):
    def test_manifest_entries_are_well_formed(self):
        self.assertTrue(seedvr2.WEIGHTS)
        for weight in seedvr2.WEIGHTS:
            self.assertEqual(set(weight), {"name", "repo", "bytes", "sha256"})
            self.assertRegex(weight["sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(weight["bytes"], 0)

    def test_manifest_names_the_main_model(self):
        names = {weight["name"] for weight in seedvr2.WEIGHTS}
        self.assertIn(seedvr2.DIT_MODEL, names)


class CliTests(unittest.TestCase):
    def run_main(self, *argv):
        with mock.patch.object(sys, "argv", ["upscale.py", *argv]):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                upscale.main()
        return raised.exception.code

    def test_rejects_non_positive_long_edge(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "in.png"
            Image.new("RGB", (4, 4)).save(source)
            self.assertEqual(self.run_main(str(source), "--long-edge", "0"), 2)

    def test_rejects_seedvr2_on_cpu(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "in.png"
            Image.new("RGB", (4, 4)).save(source)
            self.assertEqual(self.run_main(str(source), "--model", "seedvr2", "--device", "cpu"), 2)

    def test_refuses_to_overwrite_an_existing_output(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "in.png"
            output = Path(folder) / "out.png"
            Image.new("RGB", (4, 4)).save(source)
            output.write_bytes(b"existing")
            self.assertEqual(self.run_main(str(source), "-o", str(output)), 2)
            self.assertEqual(output.read_bytes(), b"existing")

    def test_requires_a_png_output_path(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "in.png"
            Image.new("RGB", (4, 4)).save(source)
            self.assertEqual(self.run_main(str(source), "-o", str(Path(folder) / "out.jpg")), 2)

    def test_empty_folder_is_an_error(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(self.run_main(folder), 2)


if __name__ == "__main__":
    unittest.main()

import os
import unittest
from pathlib import Path

from companion.__main__ import local_path


class LocalPathTest(unittest.TestCase):
    @unittest.skipIf(os.name == "nt" or not Path("/mnt/c").is_dir(), "WSL only")
    def test_windows_path_from_wsl(self):
        self.assertEqual(local_path("C:/MyGames/World of Warcraft/_forever_"),
                         Path("/mnt/c/MyGames/World of Warcraft/_forever_"))
        self.assertEqual(local_path("c:\\Games\\wow"), Path("/mnt/c/Games/wow"))

    def test_posix_path_unchanged(self):
        self.assertEqual(local_path("/home/me/wow"), Path("/home/me/wow"))


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

TOOLS_DIR = Path(__file__).resolve().parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from kanban import bootstrap_soloboard


class SoloBoardBootstrapTest(unittest.TestCase):
    def test_load_config_requires_boards_array(self) -> None:
        with tempfile.TemporaryDirectory(prefix="a3-kanban-bootstrap-") as temp_dir:
            config = Path(temp_dir) / "bootstrap.json"
            config.write_text(json.dumps({"projects": []}), encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "boards array"):
                bootstrap_soloboard.load_config(config)

    def test_main_bootstraps_selected_board_from_external_config(self) -> None:
        with tempfile.TemporaryDirectory(prefix="a3-kanban-bootstrap-") as temp_dir:
            config = Path(temp_dir) / "bootstrap.json"
            config.write_text(
                json.dumps(
                    {
                        "boards": [
                            {
                                "name": "Portal",
                                "lanes": ["To do", "Done"],
                                "tags": [{"name": "blocked", "color": "#cc3f3f"}],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            with (
                patch.object(bootstrap_soloboard.kanban_cli, "resolve_backend_context") as context,
                patch.object(bootstrap_soloboard, "ensure_board", return_value={"id": 10}),
                patch.object(bootstrap_soloboard, "ensure_lanes", return_value={"bucket_ids_by_name": {"To do": 1, "Done": 2}}),
                patch.object(bootstrap_soloboard, "ensure_tags", return_value=[{"title": "blocked"}]),
                patch("sys.argv", ["bootstrap_soloboard.py", "--config", str(config), "--board", "Portal"]),
            ):
                context.return_value.base_url = "http://localhost:3460"
                context.return_value.token = ""

                with redirect_stdout(StringIO()):
                    self.assertEqual(0, bootstrap_soloboard.main())


if __name__ == "__main__":
    unittest.main()

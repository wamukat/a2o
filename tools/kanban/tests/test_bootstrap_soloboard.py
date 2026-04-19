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

    def test_defaults_lanes_and_internal_tags_when_omitted(self) -> None:
        spec = {"name": "A2OReference", "tags": [{"name": "repo:app"}]}

        self.assertEqual(
            ["Backlog", "To do", "In progress", "In review", "Inspection", "Merging", "Done"],
            bootstrap_soloboard.board_lanes(spec),
        )
        self.assertEqual(
            ["trigger:auto-implement", "trigger:auto-parent", "blocked", "repo:app"],
            [tag["name"] for tag in bootstrap_soloboard.board_tags(spec)],
        )

    def test_explicit_lanes_and_tags_remain_supported(self) -> None:
        spec = {
            "name": "A2OReference",
            "lanes": ["Ready", "Done"],
            "tags": [{"name": "blocked", "color": "#cc3f3f"}],
        }

        self.assertEqual(["Ready", "Done"], bootstrap_soloboard.board_lanes(spec))
        tags = bootstrap_soloboard.board_tags(spec)
        self.assertEqual(["trigger:auto-implement", "trigger:auto-parent", "blocked"], [tag["name"] for tag in tags])
        self.assertEqual("#cc3f3f", tags[2]["color"])

    def test_main_bootstraps_selected_board_from_external_config(self) -> None:
        with tempfile.TemporaryDirectory(prefix="a3-kanban-bootstrap-") as temp_dir:
            config = Path(temp_dir) / "bootstrap.json"
            config.write_text(
                json.dumps(
                    {
                        "boards": [
                            {
                                "name": "A2OReference",
                                "tags": [{"name": "repo:app", "color": "#cc3f3f"}],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            with (
                patch.object(bootstrap_soloboard.kanban_cli, "resolve_backend_context") as context,
                patch.object(bootstrap_soloboard, "ensure_board", return_value={"id": 10}),
                patch.object(bootstrap_soloboard, "ensure_lanes", return_value={"bucket_ids_by_name": {"To do": 1, "Done": 2}}) as ensure_lanes,
                patch.object(bootstrap_soloboard, "ensure_tags", return_value=[{"title": "repo:app"}]) as ensure_tags,
                patch("sys.argv", ["bootstrap_soloboard.py", "--config", str(config), "--board", "A2OReference"]),
            ):
                context.return_value.base_url = "http://localhost:3460"
                context.return_value.token = ""

                with redirect_stdout(StringIO()):
                    self.assertEqual(0, bootstrap_soloboard.main())
                ensure_lanes.assert_called_once()
                self.assertEqual(bootstrap_soloboard.DEFAULT_A2O_LANES, ensure_lanes.call_args.args[3])
                self.assertEqual(
                    ["trigger:auto-implement", "trigger:auto-parent", "blocked", "repo:app"],
                    [tag["name"] for tag in ensure_tags.call_args.args[3]],
                )


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Offline regressions for report -> semantic-model workspace resolution."""

import copy
import sys
import types
import unittest
from unittest import mock

# This suite exercises pure estate-resolution logic. CI intentionally does not
# install the live auth stack, so provide inert import shims before loading the
# module; no test calls authentication or HTTP.
truststore = types.ModuleType("truststore")
truststore.inject_into_ssl = lambda: None
sys.modules.setdefault("truststore", truststore)
sys.modules.setdefault("msal", types.ModuleType("msal"))
sys.modules.setdefault("requests", types.ModuleType("requests"))

import pbi_fabric as fab


REPORT_WS = {
    "id": "11111111-1111-4111-8111-111111111111",
    "name": "Reports",
    "models": [],
    "reports": [{"id": "report-1", "name": "Employee Dashboard"}],
}
MODEL_WS = {
    "id": "22222222-2222-4222-8222-222222222222",
    "name": "Shared Models",
    "models": [{"id": "model-1", "name": "Workforce"}],
    "reports": [],
}
ESTATE = {"fetchedAt": "fixture", "workspaces": [REPORT_WS, MODEL_WS]}


class CrossWorkspaceResolutionTest(unittest.TestCase):
    def test_locate_model_owner_in_full_estate(self):
        model, workspace = fab.locate_semantic_model(
            "token", "model-1", estate=copy.deepcopy(ESTATE), use_cache=False)
        self.assertEqual("Workforce", model["name"])
        self.assertEqual(MODEL_WS["id"], workspace["id"])

    def test_scoped_report_resolves_remote_model_workspace(self):
        messages = []
        with mock.patch.object(fab, "load_estate_cache", return_value=copy.deepcopy(ESTATE)), \
             mock.patch.object(fab, "report_dataset_id", return_value="model-1"):
            hit = fab.resolve_targets(
                "token", workspace=REPORT_WS["id"], report="Employee Dashboard",
                log=messages.append)
        self.assertEqual(MODEL_WS["id"], hit["workspace"]["id"])
        self.assertEqual(MODEL_WS["id"], hit["model_workspace"]["id"])
        self.assertEqual(REPORT_WS["id"], hit["report_workspace"]["id"])
        self.assertTrue(any("uses semantic model" in message for message in messages))

    def test_same_workspace_binding_is_unchanged(self):
        same = copy.deepcopy(ESTATE)
        same["workspaces"][0]["models"] = [{"id": "model-1", "name": "Workforce"}]
        with mock.patch.object(fab, "load_estate_cache", return_value=same), \
             mock.patch.object(fab, "report_dataset_id", return_value="model-1"):
            hit = fab.resolve_targets(
                "token", workspace=REPORT_WS["id"], report="Employee Dashboard")
        self.assertEqual(REPORT_WS["id"], hit["workspace"]["id"])
        self.assertEqual(REPORT_WS["id"], hit["report_workspace"]["id"])

    def test_inaccessible_bound_model_fails_before_get_definition(self):
        partial = {"fetchedAt": "fixture", "workspaces": [copy.deepcopy(REPORT_WS)]}
        with mock.patch.object(fab, "load_estate_cache", return_value=partial), \
             mock.patch.object(fab, "enumerate_estate", return_value=partial), \
             mock.patch.object(fab, "save_estate_cache"), \
             mock.patch.object(fab, "report_dataset_id", return_value="missing-model"):
            with self.assertRaisesRegex(LookupError, "not found in any accessible workspace"):
                fab.resolve_targets(
                    "token", workspace=REPORT_WS["id"], report="Employee Dashboard")


if __name__ == "__main__":
    unittest.main()

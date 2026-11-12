import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
import sql_provenance


class ActiveDmSpecTest(unittest.TestCase):
    def test_active_choice_and_hash_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            active, other = work / 'dm-spec.json', work / 'dm-spec-reused.json'
            active.write_text('{"pages":[]}', encoding='utf-8')
            (work / 'dm-ids.json').write_text('{"dataModelId":"model-fixture"}', encoding='utf-8')
            sql_provenance.record_active_spec(work, active, 'model-fixture')
            other.write_text('{"pages":[]}', encoding='utf-8')
            os.utime(other, (active.stat().st_mtime + 60,) * 2)
            self.assertEqual(active, sql_provenance.active_spec_path(work))
            active.write_text('{"pages":[],"changed":true}', encoding='utf-8')
            with self.assertRaises(ValueError):
                sql_provenance.active_spec_path(work)
            active.write_text('{"pages":[]}', encoding='utf-8')
            (work / 'dm-ids.json').write_text('{"dataModelId":"other-model"}', encoding='utf-8')
            with self.assertRaises(ValueError):
                sql_provenance.active_spec_path(work)
            (work / 'active-dm-spec.json').unlink()
            with self.assertRaises(ValueError):
                sql_provenance.active_spec_path(work)


if __name__ == '__main__':
    unittest.main()

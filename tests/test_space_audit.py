import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import space_audit

class TestAudit(unittest.TestCase):
    def test_human_bytes(self):
        self.assertEqual(space_audit.human(500), "500.0 B")
        self.assertTrue(space_audit.human(2**31).endswith("GB"))
    def test_disk_overview(self):
        d = space_audit.disk_overview("/")
        self.assertGreater(d["total"], 0)
        self.assertTrue(0 < d["percent"] <= 100)

if __name__ == "__main__":
    unittest.main()

import ipaddress
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import gen_foreign_cidr as g


def _set(cidrs):
    return [ipaddress.ip_network(c) for c in cidrs]


class TestComplement(unittest.TestCase):
    def test_complement_of_half_space(self):
        # Excluding 0.0.0.0/1 leaves exactly 128.0.0.0/1.
        out = [str(n) for n in g.complement_v4(_set(["0.0.0.0/1"]))]
        self.assertEqual(out, ["128.0.0.0/1"])

    def test_full_space_excluded_gives_empty(self):
        self.assertEqual(g.complement_v4(_set(["0.0.0.0/0"])), [])

    def test_gap_between_two_blocks(self):
        # Exclude 0/8 and 2/8 -> the gap is exactly 1.0.0.0/8 (plus the rest above 3/8).
        out = [str(n) for n in g.complement_v4(_set(["0.0.0.0/8", "2.0.0.0/8"]))]
        self.assertIn("1.0.0.0/8", out)
        self.assertNotIn("0.0.0.0/8", out)
        self.assertNotIn("2.0.0.0/8", out)

    def test_reserved_never_in_foreign(self):
        # With realistic exclusions, private ranges must be absent from foreign.
        china = _set(["1.0.0.0/8"])
        reserved = [ipaddress.ip_network(r) for r in g.RESERVED]
        foreign = g.complement_v4(china + reserved)
        for r in ["10.0.0.0/8", "127.0.0.0/8", "192.168.0.0/16"]:
            net = ipaddress.ip_network(r)
            self.assertFalse(any(net.subnet_of(f) or net == f for f in foreign),
                             "%s leaked into foreign" % r)


class TestSafetyGate(unittest.TestCase):
    def test_small_list_refuses_and_keeps_old(self):
        with tempfile.TemporaryDirectory() as d:
            china = os.path.join(d, "china.txt")
            out = os.path.join(d, "foreign.txt")
            open(china, "w").write("1.0.0.0/8\n")            # only 1 entry (<100)
            open(out, "w").write("OLD-CONTENT\n")            # pre-existing file
            r = subprocess.run([sys.executable,
                os.path.join(HERE, "..", "scripts", "gen_foreign_cidr.py"), china, out])
            self.assertEqual(r.returncode, 1)
            self.assertEqual(open(out).read(), "OLD-CONTENT\n")  # untouched

    def test_overbroad_prefix_dropped(self):
        # A 0.0.0.0/0 line must be ignored by load_networks so a single bad entry
        # can't collapse the foreign set; narrower entries are still kept.
        with tempfile.TemporaryDirectory() as d:
            china = os.path.join(d, "china.txt")
            open(china, "w").write("0.0.0.0/0\n1.0.0.0/8\n")
            self.assertEqual([str(n) for n in g.load_networks(china)], ["1.0.0.0/8"])

    def test_empty_foreign_refused_keeps_old(self):
        # A china list covering the whole space -> empty foreign -> refuse (exit 1)
        # and never blank an existing foreign file.
        with tempfile.TemporaryDirectory() as d:
            china = os.path.join(d, "china.txt")
            out = os.path.join(d, "foreign.txt")
            with open(china, "w") as f:
                for i in range(256):
                    f.write("%d.0.0.0/8\n" % i)
            open(out, "w").write("OLD-CONTENT\n")
            r = subprocess.run([sys.executable,
                os.path.join(HERE, "..", "scripts", "gen_foreign_cidr.py"), china, out])
            self.assertEqual(r.returncode, 1)
            self.assertEqual(open(out).read(), "OLD-CONTENT\n")  # untouched


if __name__ == "__main__":
    unittest.main()

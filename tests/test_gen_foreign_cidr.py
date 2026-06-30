"""
test_gen_foreign_cidr.py — OBSOLETE

gen_foreign_cidr.py was removed in the smartdns → 5gpn-dns migration (Task 8).
The foreign-cidr.txt approach (complement of chnroute) was replaced by the
5gpn-dns deterministic chnroute membership check (china_ip_list.txt, positive set).

This file is retained for git history traceability but all tests are skipped.
"""
import unittest


@unittest.skip("gen_foreign_cidr.py removed — 5gpn-dns uses china_ip_list.txt directly")
class TestComplement(unittest.TestCase):
    pass


@unittest.skip("gen_foreign_cidr.py removed — 5gpn-dns uses china_ip_list.txt directly")
class TestSafetyGate(unittest.TestCase):
    pass


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""
Tests for INSIGHT_workbook_reader.py.

The fixtures are built in memory rather than checked in. A real configuration
workbook is client data -- legal entities, tax identifiers, staff emails -- and
committing one as a test fixture would publish it. So each test constructs a
workbook with the shape it needs to exercise, and the shapes are taken from
what real ones actually do.

Run: python -m unittest test_INSIGHT_workbook_reader -v
"""

import os
import tempfile
import unittest

import openpyxl

import INSIGHT_workbook_reader as reader


def make_workbook(sheets):
    """sheets: {name: [[row values], ...]} -> path to a temporary .xlsx"""
    wb = openpyxl.Workbook()
    wb.remove(wb.active)
    for name, rows in sheets.items():
        ws = wb.create_sheet(title=name)
        for row in rows:
            ws.append(row)
    fd, path = tempfile.mkstemp(suffix=".xlsx")
    os.close(fd)
    wb.save(path)
    return path


class DigestShapeTests(unittest.TestCase):
    def setUp(self):
        self.paths = []

    def tearDown(self):
        for p in self.paths:
            os.unlink(p)

    def build(self, sheets):
        p = make_workbook(sheets)
        self.paths.append(p)
        return p

    def test_every_value_carries_its_cell_address(self):
        path = self.build({"Ledger": [["Name", "Currency"], ["OCWI", "USD"]]})
        d = reader.digest_workbook(path)
        refs = {c["ref"]: c["value"] for row in d["sheets"][0]["rows"] for c in row}
        # Without an address a proposed answer cannot be checked, which is the
        # whole reason this module exists.
        self.assertEqual(refs["Ledger!A1"], "Name")
        self.assertEqual(refs["Ledger!B2"], "USD")

    def test_facts_above_a_later_table_survive(self):
        # The failure that killed an earlier version: a key/value preamble
        # followed by a wide table. Header detection picked the table and
        # discarded the preamble -- which is where the answers were.
        path = self.build({"Manage Accounting Calendar": [
            ["Back to Index"],
            ["Period Frequency", "Monthly"],
            ["Adjusting Period Frequency", "Twice at year end"],
            ["Format", "MMMYYYY Calendar Year"],
            ["Period", "Year", "Period Number", "Start Date", "End Date"],
            ["JAN-1951", 1951, 1, "1951-01-01", "1951-01-31"],
            ["FEB-1951", 1951, 2, "1951-02-01", "1951-02-28"],
        ]})
        text = reader.digest_to_text(reader.digest_workbook(path))
        self.assertIn("Twice at year end", text)
        self.assertIn("MMMYYYY", text)

    def test_a_long_sheet_is_sampled_across_its_whole_range(self):
        rows = [["Approval Group", "Member", "Type"]]
        rows += [["GL Finance", "person%d@example.gov" % i, "user"] for i in range(200)]
        path = self.build({"Journal Approval": rows})
        d = reader.digest_workbook(path)
        text = reader.digest_to_text(d)
        sheet = d["sheets"][0]
        self.assertGreater(sheet["omitted_rows"], 0, "a 201-row sheet must not be kept whole")

        # What spread sampling promises is coverage of the range, not that any
        # particular row is caught. Rows from the top and from deep in the
        # sheet both appear.
        sampled_rows = [int(c["ref"].split("!")[1][1:])
                        for row in sheet["rows"] for c in row[:1]]
        self.assertLess(min(sampled_rows), 5)
        self.assertGreater(max(sampled_rows), 150)

    def test_a_short_sheet_is_kept_whole_so_every_member_is_visible(self):
        # This is the case that matters in practice and the reason the
        # keep-whole threshold exists. The reference workbook's approval sheet
        # carries 13 members, all on one email domain that does not match the
        # legal entity -- a contradiction only visible if every member is
        # present rather than sampled.
        rows = [["Approval Group", "Member", "Type"]]
        rows += [["GL Finance", "person%d@otherplace.gov" % i, "user"] for i in range(13)]
        path = self.build({"Journal Approval": rows})
        d = reader.digest_workbook(path)
        self.assertEqual(d["sheets"][0]["omitted_rows"], 0)
        text = reader.digest_to_text(d)
        self.assertEqual(text.count("@otherplace.gov"), 13)

    def test_the_omitted_count_is_reported_because_it_is_itself_an_answer(self):
        rows = [["Value", "Description"]] + [["1%03d" % i, "Fund %d" % i] for i in range(500)]
        path = self.build({"Manage COA Segment Values": rows})
        d = reader.digest_workbook(path)
        sheet = d["sheets"][0]
        self.assertGreater(sheet["omitted_rows"], 400)
        # "how many segment values are there" is answered by the count alone.
        self.assertIn("further rows", reader.digest_to_text(d))

    def test_template_instructions_are_dropped(self):
        path = self.build({"Ledger": [
            ["Ledger Name", "Currency", "Accounting Method"],
            ["30 Characters", "List of Values", "List of Values"],
            ["OCWI", "USD", "OCWI Accrual with Encumbrances"],
        ]})
        text = reader.digest_to_text(reader.digest_workbook(path))
        # Guidance is identical in every client's copy and says nothing about
        # this one; the answer beneath it is what matters.
        self.assertNotIn("30 Characters", text)
        self.assertIn("OCWI Accrual with Encumbrances", text)

    def test_every_sheet_gets_a_share_of_the_budget(self):
        wide = [["c%d" % c for c in range(30)] for _ in range(200)]
        sheets = {"Sheet%d" % i: list(wide) for i in range(8)}
        sheets["Last"] = [["Ledger Name"], ["OCWI"]]
        path = self.build(sheets)
        d = reader.digest_workbook(path, max_chars=20000)
        names = [s["name"] for s in d["sheets"]]
        # Spending the budget first-come would drop whichever sheets happen to
        # sit at the end of the tab order, which in a real workbook is where
        # the intercompany and approval sheets live.
        self.assertIn("Last", names)
        self.assertIn("OCWI", reader.digest_to_text(d))

    def test_an_empty_sheet_is_skipped_rather_than_emitted_blank(self):
        path = self.build({"Empty": [], "Ledger": [["Name"], ["OCWI"]]})
        d = reader.digest_workbook(path)
        self.assertEqual([s["name"] for s in d["sheets"]], ["Ledger"])


class CellLookupTests(unittest.TestCase):
    def setUp(self):
        self.path = make_workbook({"Ledger": [["Name", "Currency"], ["OCWI", "USD"]],
                                   "Legal Entity": [["EIN"], ["39-6005724"]]})

    def tearDown(self):
        os.unlink(self.path)

    def test_reads_the_cell_that_was_cited(self):
        got = reader.read_cells(self.path, ["Ledger!B2", "Legal Entity!A2"])
        self.assertEqual(got["Ledger!B2"], "USD")
        self.assertEqual(got["Legal Entity!A2"], "39-6005724")

    def test_a_sheet_name_with_a_space_works_quoted_or_not(self):
        self.assertEqual(reader.parse_ref("'Legal Entity'!A2"), ("Legal Entity", "A", 2))
        self.assertEqual(reader.parse_ref("Legal Entity!A2"), ("Legal Entity", "A", 2))

    def test_nonsense_and_out_of_range_come_back_empty_not_as_errors(self):
        got = reader.read_cells(self.path, ["Ledger!ZZ9999", "not a reference", "Ghost!A1"])
        self.assertEqual(set(got.values()), {""})


class CitationVerificationTests(unittest.TestCase):
    def test_an_answer_drawn_from_the_cell_is_supported(self):
        res = reader.verify_citations(
            "USD, with accounting method OCWI Accrual with Encumbrances.",
            {"Ledger!F9": "OCWI Accrual with Encumbrances"})
        self.assertEqual(res["status"], "supported")
        self.assertEqual(res["matched_refs"], ["Ledger!F9"])

    def test_an_answer_unrelated_to_its_citation_is_unsupported(self):
        # The fabrication that matters: a confident answer pointing at a real
        # cell that says nothing of the kind.
        res = reader.verify_citations(
            "The client runs a 4-4-5 retail calendar.",
            {"Ledger!F9": "OCWI Accrual with Encumbrances"})
        self.assertEqual(res["status"], "unsupported")

    def test_citing_an_empty_cell_counts_as_no_citation(self):
        res = reader.verify_citations("Something stated confidently.", {"Ledger!F400": ""})
        self.assertEqual(res["status"], "uncited")
        self.assertEqual(res["empty_refs"], ["Ledger!F400"])

    def test_no_citations_at_all_is_uncited(self):
        self.assertEqual(reader.verify_citations("An answer.", {})["status"], "uncited")

    def test_a_summary_of_several_cells_still_verifies(self):
        # The reason the check cannot be stricter than token overlap: a good
        # answer condenses several cells into a sentence, so demanding the
        # cell text appear verbatim would reject exactly the answers worth
        # having.
        res = reader.verify_citations(
            "Six segments: Fund(5), Cost Center(6), Program(5), Natural Account(6).",
            {"S!A1": "Fund", "S!A2": "Cost Center", "S!A3": "Program", "S!A4": "Natural Account"})
        self.assertEqual(res["status"], "supported")
        self.assertEqual(res["overlap"], 1.0)


if __name__ == "__main__":
    unittest.main()

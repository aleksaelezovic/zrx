"""Finite CLI simulations. Python observes persisted state; it implements no checkout.

Every invocation is a new process, with closed stdin, captured output and
a five-second timeout (subprocess.run kills/waits on timeout). TemporaryDirectory
owns all databases/journals. Fault hooks are synchronous, never sleep-scheduled.
"""

import contextlib
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest


EXE = str(pathlib.Path(sys.argv.pop(1)).resolve())
USAGE = ("Usage: durable-checkout DB KEY CART CENTS [--fault POINT]\n"
         "       durable-checkout --help\n"
         "POINT: after-begin | after-insert | after-commit | rollback | output\n")
if sqlite3.sqlite_version_info < (3, 37, 0):
    raise SystemExit("Integration tests require Python's sqlite3 >= 3.37 (STRICT tables)")


class CheckoutProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zrx-checkout-")
        self.addCleanup(self.temp.cleanup)
        self.db = pathlib.Path(self.temp.name) / "checkout.db"

    def invoke(self, key="key-a", cart="cart-a", cents="2500", fault=None,
               code=0, out=None, err=""):
        args = [EXE, str(self.db), key, cart, cents]
        if fault:
            args += ["--fault", fault]
        result = subprocess.run(args, input="", capture_output=True, text=True,
                                timeout=5, check=False)
        self.assertEqual(result.returncode, code, result)
        if out is not None:
            self.assertEqual(result.stdout, out, result)
        self.assertEqual(result.stderr, err, result)
        return result.stdout

    def rows(self):
        # Called after the app itself has recovered crash tests.
        with contextlib.closing(sqlite3.connect(self.db, timeout=1)) as db, db:
            self.assertEqual(db.execute("PRAGMA integrity_check").fetchall(), [("ok",)])
            self.assertEqual(db.execute("PRAGMA application_id").fetchone(), (1515340619,))
            self.assertEqual(db.execute("PRAGMA user_version").fetchone(), (1,))
            return db.execute("SELECT id, key, cart, cents FROM checkouts ORDER BY id").fetchall()

    def test_help_terminates_without_reading_input_or_opening_storage(self):
        result = subprocess.run([EXE, "--help"], input="", capture_output=True,
                                text=True, cwd=self.temp.name, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(result.stdout, USAGE)
        self.assertEqual(result.stderr, "")
        self.assertEqual(list(pathlib.Path(self.temp.name).iterdir()), [])

    def test_invalid_command_reports_usage_once_without_creating_database(self):
        result = subprocess.run([EXE, str(self.db), "--help"], input="",
                                capture_output=True, text=True, cwd=self.temp.name,
                                timeout=5, check=False)
        self.assertEqual(result.returncode, 2, result)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "error: InvalidArguments\n" + USAGE)
        self.assertEqual(list(pathlib.Path(self.temp.name).iterdir()), [])

    def test_success_duplicate_and_conflicts_across_restarts(self):
        self.invoke(out="issued checkout=1 cart=cart-a cents=2500\n")
        self.assertEqual(self.rows(), [(1, "key-a", "cart-a", 2500)])
        # Numeric amount identity, not byte identity of the CLI representation.
        self.invoke(cents="02500", out="reused checkout=1 cart=cart-a cents=2500\n")
        self.invoke(cart="cart-b", code=3, out="", err="error: Conflict\n")
        self.invoke(cents="2501", code=3, out="", err="error: Conflict\n")
        self.assertEqual(self.rows(), [(1, "key-a", "cart-a", 2500)])
        self.invoke(key="key-b", out="issued checkout=2 cart=cart-a cents=2500\n")
        self.assertEqual(self.rows(), [
            (1, "key-a", "cart-a", 2500), (2, "key-b", "cart-a", 2500)])

    def test_key_and_cart_identity_are_case_sensitive(self):
        self.invoke(out="issued checkout=1 cart=cart-a cents=2500\n")
        self.invoke(cart="Cart-a", code=3, out="", err="error: Conflict\n")
        self.invoke(key="Key-a", out="issued checkout=2 cart=cart-a cents=2500\n")
        self.assertEqual(len(self.rows()), 2)

    def test_largest_amount_and_identifiers_round_trip(self):
        key, cart = "K" * 64, "C" * 64
        self.invoke(key=key, cart=cart, cents="4294967295",
                    out=f"issued checkout=1 cart={cart} cents=4294967295\n")
        self.invoke(key=key, cart=cart, cents="4294967295",
                    out=f"reused checkout=1 cart={cart} cents=4294967295\n")
        self.assertEqual(self.rows(), [(1, key, cart, 4294967295)])

    def test_crash_after_begin_leaves_no_issuance(self):
        self.invoke(fault="after-begin", code=85, out="")
        # App, not Python's SQLite, is the first opener after abrupt termination.
        self.invoke(key="other", out="issued checkout=1 cart=cart-a cents=2500\n")
        self.assertEqual(self.rows(), [(1, "other", "cart-a", 2500)])
        self.invoke(out="issued checkout=2 cart=cart-a cents=2500\n")
        self.assertEqual(self.rows(), [
            (1, "other", "cart-a", 2500), (2, "key-a", "cart-a", 2500)])

    def test_crash_after_insert_recovers_uncommitted_transaction(self):
        self.invoke(fault="after-insert", code=86, out="")
        self.assertTrue(pathlib.Path(str(self.db) + "-journal").exists())
        self.invoke(key="other", out="issued checkout=1 cart=cart-a cents=2500\n")
        self.assertEqual(self.rows(), [(1, "other", "cart-a", 2500)])
        self.invoke(out="issued checkout=2 cart=cart-a cents=2500\n")
        self.invoke(out="reused checkout=2 cart=cart-a cents=2500\n")
        self.assertEqual(self.rows(), [
            (1, "other", "cart-a", 2500), (2, "key-a", "cart-a", 2500)])

    def test_crash_after_commit_before_acknowledgement_reuses_receipt(self):
        self.invoke(fault="after-commit", code=87, out="")
        self.invoke(out="reused checkout=1 cart=cart-a cents=2500\n")
        self.invoke(cart="other", code=3, out="", err="error: Conflict\n")
        self.assertEqual(self.rows(), [(1, "key-a", "cart-a", 2500)])

    def test_operation_failure_rolls_back_before_restart(self):
        self.invoke(fault="rollback", code=1, out="", err="error: InjectedFailure\n")
        self.assertEqual(self.rows(), [])
        self.invoke(out="issued checkout=1 cart=cart-a cents=2500\n")
        self.assertEqual(self.rows(), [(1, "key-a", "cart-a", 2500)])

    def test_terminal_failure_does_not_undo_committed_issuance(self):
        self.invoke(fault="output", code=1, out="", err="error: OutputUnavailable\n")
        self.assertEqual(self.rows(), [(1, "key-a", "cart-a", 2500)])
        self.invoke(out="reused checkout=1 cart=cart-a cents=2500\n")
        self.assertEqual(self.rows(), [(1, "key-a", "cart-a", 2500)])

    def test_lock_contention_is_bounded_and_does_not_issue(self):
        self.invoke(out="issued checkout=1 cart=cart-a cents=2500\n")
        with contextlib.closing(sqlite3.connect(self.db, timeout=1)) as lock:
            lock.execute("BEGIN IMMEDIATE")
            try:
                self.invoke(key="key-b", code=1, out="", err="error: Busy\n")
                self.assertEqual(lock.execute("SELECT count(*) FROM checkouts").fetchone(), (1,))
            finally:
                lock.rollback()
        self.invoke(key="key-b", out="issued checkout=2 cart=cart-a cents=2500\n")
        self.assertEqual(self.rows(), [
            (1, "key-a", "cart-a", 2500), (2, "key-b", "cart-a", 2500)])

    def test_invalid_input_never_opens_database(self):
        for key, cart, cents in [("", "c", "1"), ("k", "bad cart", "1"),
                                 ("k", "c", "0"), ("k", "c", "4294967296"),
                                 ("k", "c", "1x"), ("k" * 65, "c", "1")]:
            with self.subTest(key=key, cart=cart, cents=cents):
                args = [EXE, str(self.db), key, cart, cents]
                result = subprocess.run(args, input="", capture_output=True, text=True,
                                        timeout=5, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "error: InvalidArguments\n" + USAGE)
                self.assertFalse(self.db.exists())

    def test_open_failure_never_reports_success(self):
        self.db = pathlib.Path(self.temp.name) / "missing" / "checkout.db"
        self.invoke(code=1, out="", err="error: Storage\n")
        self.assertFalse(self.db.exists())

    def test_foreign_and_future_databases_are_not_adopted(self):
        with contextlib.closing(sqlite3.connect(self.db)) as db, db:
            db.execute("CREATE TABLE unrelated (value TEXT)")
            db.execute("INSERT INTO unrelated VALUES ('keep')")
        self.invoke(code=1, out="", err="error: IncompatibleDatabase\n")
        with contextlib.closing(sqlite3.connect(self.db)) as db, db:
            self.assertEqual(db.execute("SELECT * FROM unrelated").fetchall(), [("keep",)])
            self.assertEqual(db.execute("PRAGMA user_version").fetchone(), (0,))
            self.assertEqual(db.execute(
                "SELECT name FROM sqlite_schema WHERE type='table'").fetchall(), [("unrelated",)])

        self.db = pathlib.Path(self.temp.name) / "future.db"
        self.invoke(out="issued checkout=1 cart=cart-a cents=2500\n")
        with contextlib.closing(sqlite3.connect(self.db)) as db, db:
            db.execute("PRAGMA user_version = 2")
        self.invoke(code=1, out="", err="error: IncompatibleDatabase\n")
        with contextlib.closing(sqlite3.connect(self.db)) as db, db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone(), (2,))
            self.assertEqual(db.execute("SELECT id, key, cart, cents FROM checkouts").fetchall(),
                             [(1, "key-a", "cart-a", 2500)])


if __name__ == "__main__":
    unittest.main(verbosity=2)

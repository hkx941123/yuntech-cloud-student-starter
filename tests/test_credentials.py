import configparser
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import lab

CTX = {"account": "000000000000", "region": "us-east-1"}
IDENTITY = {"Account": CTX["account"], "Arn": "arn:aws:sts::000000000000:assumed-role/test/session"}


class CredentialTests(unittest.TestCase):
    def test_configure_verifies_before_saving_and_keeps_secrets_out_of_output(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            with patch("lab.Path.home", return_value=home), patch("sys.stdin.isatty", return_value=True), \
                 patch("builtins.input", side_effect=["", CTX["account"]]), \
                 patch("lab.getpass.getpass", side_effect=["fake-access", "fake-secret", "fake-session"]), \
                 patch("lab.run_aws", return_value=IDENTITY), patch("sys.stdout", new_callable=io.StringIO) as output:
                lab.configure()
                self.assertTrue((home / ".aws/credentials").is_file())
                self.assertEqual(json.loads((home / ".aws/learnerlab-context.json").read_text()), CTX)
                self.assertNotIn("fake-secret", output.getvalue())
                self.assertNotIn("fake-session", output.getvalue())
                self.assertEqual(list(home.glob("learnerlab-*")), [])

    def test_failed_configure_preserves_working_profile(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            (home / ".aws").mkdir()
            original = "[learnerlab]\naws_session_token=old-synthetic-token\n"
            (home / ".aws/credentials").write_text(original)
            with patch("lab.Path.home", return_value=home), patch("sys.stdin.isatty", return_value=True), \
                 patch("builtins.input", side_effect=["", CTX["account"]]), \
                 patch("lab.getpass.getpass", side_effect=["fake-access", "fake-secret", "fake-session"]), \
                 patch("lab.run_aws", side_effect=lab.LabError("ExpiredToken")):
                with self.assertRaises(lab.LabError):
                    lab.configure()
            self.assertEqual((home / ".aws/credentials").read_text(), original)
            self.assertFalse((home / ".aws/learnerlab-context.json").exists())
            self.assertEqual(list(home.glob("learnerlab-*")), [])

    def test_preserve_other_profiles_and_clear_stale_settings(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "credentials"
            path.write_text("[personal]\nregion=example\n[learnerlab]\ncredential_process=wrong-command\n")
            lab.profile_update(path, "learnerlab", {"aws_session_token": "synthetic-test-value"})
            p = configparser.RawConfigParser()
            p.read(path)
            self.assertEqual(p["personal"]["region"], "example")
            self.assertNotIn("credential_process", p["learnerlab"])
            if os.name != "nt":
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            lab.profile_update(path, "learnerlab", None)
            p = configparser.RawConfigParser()
            p.read(path)
            self.assertFalse(p.has_section("learnerlab"))
            self.assertTrue(p.has_section("personal"))

    def test_environment_cannot_override_account_or_endpoint(self):
        with patch.dict(os.environ, {"AWS_ACCESS_KEY_ID": "wrong", "AWS_ENDPOINT_URL": "http://evil.test", "AWS_ROLE_ARN": "wrong", "TF_VAR_expected_account_id": "wrong", "TF_CLI_ARGS_apply": "-auto-approve", "TF_LOG": "TRACE"}):
            env = lab.clean_env("us-west-2")
        for key in ("AWS_ACCESS_KEY_ID", "AWS_ENDPOINT_URL", "AWS_ROLE_ARN", "TF_VAR_expected_account_id", "TF_CLI_ARGS_apply", "TF_LOG"):
            self.assertNotIn(key, env)
        self.assertEqual(env["AWS_PROFILE"], "learnerlab")
        self.assertEqual(env["AWS_REGION"], "us-west-2")

    @patch("lab.run_aws", return_value={"Account": "111111111111"})
    def test_wrong_account_stops(self, aws):
        with self.assertRaisesRegex(lab.LabError, "Account mismatch"):
            lab.verify(CTX)

    @patch("lab.run_aws", return_value={"Account": CTX["account"], "Arn": "arn:aws:iam::000000000000:user/test"})
    def test_iam_user_rejected(self, aws):
        with self.assertRaisesRegex(lab.LabError, "assumed-role"):
            lab.verify(CTX)

    @patch("sys.stdin.isatty", return_value=False)
    def test_no_piped_secrets(self, tty):
        with self.assertRaises(lab.LabError):
            lab.configure()

    @patch("sys.stdin.isatty", return_value=False)
    def test_noninteractive_approval_rejected(self, tty):
        with self.assertRaises(lab.LabError):
            lab.approve("delete scoped object", "confirm")

    @patch("subprocess.run")
    def test_errors_are_sanitized(self, run):
        run.return_value = subprocess.CompletedProcess([], 255, "", "An error occurred (ExpiredToken) secret-value-SHOULD-NOT-PRINT")
        with self.assertRaises(lab.LabError) as result:
            lab.run_aws(["sts", "get-caller-identity"], "us-east-1")
        self.assertIn("ExpiredToken", str(result.exception))
        self.assertNotIn("SHOULD-NOT-PRINT", str(result.exception))

    @patch("subprocess.run")
    def test_aws_arguments_no_shell(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, "{}", "")
        lab.run_aws(["sts", "get-caller-identity"], "us-east-1")
        args, kwargs = run.call_args
        self.assertIsInstance(args[0], list)
        self.assertNotIn("shell", kwargs)
        self.assertEqual(args[0][1:3], ["--profile", "learnerlab"])

    @patch("lab.run_aws", side_effect=lab.LabError("AccessDenied"))
    def test_access_denied_never_retries_iam(self, aws):
        with self.assertRaises(lab.LabError):
            lab.verify(CTX)
        aws.assert_called_once()

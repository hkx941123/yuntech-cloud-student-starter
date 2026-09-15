"""Classroom boundaries: avoid paid fallback, silent writes, and public sharing."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OpenCodeBoundaries(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((ROOT / 'opencode.json').read_text(encoding='utf-8'))

    def test_both_model_roles_and_provider_allowlist_are_explicit(self):
        self.assertEqual(self.config['model'], 'opencode/big-pickle')
        self.assertEqual(self.config['small_model'], self.config['model'])
        self.assertEqual(self.config['enabled_providers'], ['opencode'])
        self.assertEqual(self.config['provider']['opencode']['whitelist'], ['big-pickle'])

    def test_shell_and_edit_cannot_run_without_student_confirmation(self):
        p = self.config['permission']
        self.assertEqual(p['bash']['*'], 'ask')
        self.assertEqual(p['edit']['*'], 'ask')
        self.assertNotIn('allow', p['bash'].values())
        for agent in self.config['agent'].values():
            self.assertNotIn('permission', agent, 'An agent override can weaken course permissions')

    def test_sensitive_file_and_external_access_have_explicit_denials(self):
        p = self.config['permission']
        self.assertEqual(p['external_directory'], 'deny')
        for pattern in ('**/.aws/**', '**/.env*', '**/*.pem', '**/*.key', '**/auth.json', '**/credentials'):
            self.assertEqual(p['read'][pattern], 'deny', pattern)
            self.assertEqual(p['edit'][pattern], 'deny', pattern)

    def test_no_public_sharing_or_automatic_version_drift(self):
        self.assertEqual(self.config['share'], 'disabled')
        self.assertIs(self.config['autoupdate'], False)
        for name in self.config['instructions']:
            self.assertTrue((ROOT / name).is_file())


if __name__ == '__main__':
    unittest.main()

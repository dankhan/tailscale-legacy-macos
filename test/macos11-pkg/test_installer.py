#!/usr/bin/env python3
"""Sandboxed script checks: every absolute install path is rewritten to a temp root."""
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[2]
ASSETS = pathlib.Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else REPO / "dist/release-assets"
CLI_ARCHIVE = ASSETS / "tailscale-macos11-x86_64-v1.104.4.tar.gz"
GUI_ARCHIVE = ASSETS / "TailscaleMenu-macos11-x86_64-v1.104.4.zip"


class InstallerScripts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tailscale-pkg-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name) / "target"
        self.mock = pathlib.Path(self.temp.name) / "mock"
        self.mock.mkdir()
        for path in ("usr/local/bin", "Applications", "Library/LaunchDaemons", "var/backups"):
            (self.root / path).mkdir(parents=True)
        self.job_state = pathlib.Path(self.temp.name) / "job"
        self.job_state.write_text("0")
        self.env = dict(os.environ, JOB_STATE=str(self.job_state), TEST_OS="11.7.11", TEST_ARCH="x86_64",
                        EXPECTED_PROGRAM=str(self.root / "usr/local/bin/tailscaled"))
        self._mock("id", "echo 0")
        self._mock("sw_vers", "echo \"$TEST_OS\"")
        self._mock("uname", "echo \"$TEST_ARCH\"")
        self._mock("chown", "exit 0")
        self._mock("sleep", "exit 0")
        self._mock("install", "[ \"$1\" = -d ] || exit 2; mkdir -p \"${@: -1}\"")
        self._mock("pgrep", '''case "$2" in
            TailscaleMenu) [ "${RUNNING_GUI:-0}" = 1 ] && echo 12345 ;;
            tailscaled) [ "${UNRELATED_DAEMON:-0}" = 1 ] && echo 12346 || { [ "$(cat "$JOB_STATE")" = 1 ] && echo 999999; } ;;
            esac''')
        self._mock("launchctl", '''case "$1" in
            print) [ "$(cat "$JOB_STATE")" = 1 ] || exit 1; if [ "${WRONG_JOB:-0}" = 1 ]; then echo 'program = /other/tailscaled'; else echo "program = $EXPECTED_PROGRAM"; fi; echo 'pid = 999999' ;;
            bootout) [ "$(cat "$JOB_STATE")" = 1 ] || exit 1; echo 0 > "$JOB_STATE" ;;
            bootstrap) [ "${BOOTSTRAP_FAIL:-0}" = 1 ] && exit 1; echo 1 > "$JOB_STATE" ;;
            *) exit 2 ;;
            esac''')
        self.pre = self._patched("preinstall")
        self.post = self._patched("postinstall")
        self._patched_validator()

    def _mock(self, name, body):
        path = self.mock / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def _patched(self, name):
        script = (REPO / "installer/macos11-scripts" / name).read_text()
        commands = {
            "/usr/bin/id": "id", "/usr/bin/sw_vers": "sw_vers", "/usr/bin/uname": "uname",
            "/usr/bin/pgrep": "pgrep", "/bin/launchctl": "launchctl",
            "/usr/sbin/chown": "chown", "/bin/sleep": "sleep", "/usr/bin/install": "install",
        }
        for original, mock in commands.items():
            script = script.replace(original, str(self.mock / mock))
        for original in ("/usr/local", "/Applications", "/Library", "/var/lib", "/var/backups"):
            script = script.replace(original, str(self.root / original.lstrip("/")))
        path = pathlib.Path(self.temp.name) / name
        path.write_text(script)
        path.chmod(0o755)
        return path

    def _patched_validator(self):
        script = (REPO / "installer/macos11-scripts/validate-plist.rb").read_text()
        for original in ("/usr/local", "/var/lib"):
            script = script.replace(original, str(self.root / original.lstrip("/")))
        path = pathlib.Path(self.temp.name) / "validate-plist.rb"
        path.write_text(script)

    def run_script(self, path):
        return subprocess.run([str(path), "com.dankhan.tailscale-macos11-intel", "1.104.4", "/"],
                              env=self.env, text=True, capture_output=True)

    def install_payload(self):
        with tarfile.open(CLI_ARCHIVE, "r:gz") as archive:
            for name in ("tailscale", "tailscaled"):
                with archive.extractfile(name) as source, (self.root / "usr/local/bin" / name).open("wb") as target:
                    shutil.copyfileobj(source, target)
        with zipfile.ZipFile(GUI_ARCHIVE) as archive:
            archive.extractall(self.root / "Applications")
        self.write_plist()

    def write_plist(self):
        (self.root / "Library/LaunchDaemons/com.tailscale.tailscaled.plist").write_text(self.plist_text())

    def plist_text(self):
        source = (REPO / "deploy/com.tailscale.tailscaled.macos11.plist").read_text()
        for original in ("/usr/local", "/var/lib"):
            source = source.replace(original, str(self.root / original.lstrip("/")))
        return source

    def existing_install(self):
        (self.root / "usr/local/bin/tailscale").write_text("old CLI")
        (self.root / "usr/local/bin/tailscaled").write_text("old daemon")
        self.write_plist()
        state = self.root / "var/lib/tailscale/tailscaled.state"
        state.parent.mkdir(parents=True)
        state.write_text("identity sentinel")
        self.job_state.write_text("1")
        return state

    def test_fresh_install(self):
        self.assertEqual(self.run_script(self.pre).returncode, 0)
        self.install_payload()
        result = self.run_script(self.post)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.job_state.read_text().strip(), "1")
        self.assertFalse((self.root / "var/backups/tailscale-macos11-installer/pending-backup").exists())
        self.assertTrue((self.root / "var/lib/tailscale").is_dir())

    def test_fresh_install_without_usr_local(self):
        shutil.rmtree(self.root / "usr/local")
        self.assertEqual(self.run_script(self.pre).returncode, 0)
        (self.root / "usr/local/bin").mkdir(parents=True)
        self.install_payload()
        result = self.run_script(self.post)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_upgrade_preserves_state_and_backs_up_program_files(self):
        state = self.existing_install()
        result = self.run_script(self.pre)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.job_state.read_text().strip(), "0")
        backup = next((self.root / "var/backups/tailscale-macos11-installer").glob("upgrade.*"))
        self.assertEqual((backup / "tailscaled").read_text(), "old daemon")
        self.assertTrue((backup / "com.tailscale.tailscaled.plist").is_file())
        self.install_payload()
        self.assertEqual(self.run_script(self.post).returncode, 0)
        self.assertEqual(state.read_text(), "identity sentinel")
        self.assertEqual(self.job_state.read_text().strip(), "1")
        self.assertFalse((self.root / "var/backups/tailscale-macos11-installer/pending-backup").exists())

    def test_rejects_unsupported_targets_before_changes(self):
        for key, value in (("TEST_OS", "12.0"), ("TEST_ARCH", "arm64")):
            with self.subTest(key=key):
                self.env[key] = value
                self.assertNotEqual(self.run_script(self.pre).returncode, 0)
                self.assertEqual(self.job_state.read_text().strip(), "0")
                self.env[key] = "11.7.11" if key == "TEST_OS" else "x86_64"

    def test_rejects_running_gui_and_unrelated_daemon(self):
        self.existing_install()
        self.env["RUNNING_GUI"] = "1"
        app = self.root / "Applications/TailscaleMenu.app/Contents"
        app.mkdir(parents=True)
        with zipfile.ZipFile(GUI_ARCHIVE) as archive:
            (app / "Info.plist").write_bytes(archive.read("TailscaleMenu.app/Contents/Info.plist"))
        self.assertNotEqual(self.run_script(self.pre).returncode, 0)
        self.env.pop("RUNNING_GUI")
        self.env["UNRELATED_DAEMON"] = "1"
        self.assertNotEqual(self.run_script(self.pre).returncode, 0)
        self.assertEqual(self.job_state.read_text().strip(), "1")

    def test_rejects_changed_socket(self):
        self.existing_install()
        plist = self.root / "Library/LaunchDaemons/com.tailscale.tailscaled.plist"
        plist.write_text(plist.read_text().replace("/var/run/tailscaled.socket", "/tmp/other.socket"))
        self.assertNotEqual(self.run_script(self.pre).returncode, 0)
        self.assertEqual(self.job_state.read_text().strip(), "1")

    def test_rejects_other_custom_plist_settings(self):
        self.existing_install()
        plist = self.root / "Library/LaunchDaemons/com.tailscale.tailscaled.plist"
        plist.write_text(plist.read_text().replace("</dict>", "<key>Disabled</key><true/>\n</dict>"))
        self.assertNotEqual(self.run_script(self.pre).returncode, 0)
        self.assertEqual(self.job_state.read_text().strip(), "1")

    def test_accepts_verified_legacy_plist(self):
        self.existing_install()
        with tarfile.open(CLI_ARCHIVE, "r:gz") as archive:
            with archive.extractfile("tailscaled") as source, (self.root / "usr/local/bin/tailscaled").open("wb") as target:
                shutil.copyfileobj(source, target)
        plist = self.root / "Library/LaunchDaemons/com.tailscale.tailscaled.plist"
        xml = plist.read_text().replace("<string>--tun=utun</string>", "")
        xml = xml.replace("<key>RunAtLoad</key>",
                          "<key>EnvironmentVariables</key><dict><key>GODEBUG</key><string>x509usefallbackroots=1</string></dict>\n<key>RunAtLoad</key>")
        plist.write_text(xml)
        result = self.run_script(self.pre)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.job_state.read_text().strip(), "0")

    def test_rejects_implicit_tun_with_unverified_daemon(self):
        self.existing_install()
        plist = self.root / "Library/LaunchDaemons/com.tailscale.tailscaled.plist"
        plist.write_text(plist.read_text().replace("<string>--tun=utun</string>", ""))
        self.assertNotEqual(self.run_script(self.pre).returncode, 0)
        self.assertEqual(self.job_state.read_text().strip(), "1")

    def test_rejects_custom_environment_and_loaded_job(self):
        self.existing_install()
        plist = self.root / "Library/LaunchDaemons/com.tailscale.tailscaled.plist"
        plist.write_text(plist.read_text().replace("<key>RunAtLoad</key>",
                          "<key>EnvironmentVariables</key><dict><key>OTHER</key><string>unsafe</string></dict>\n<key>RunAtLoad</key>"))
        self.assertNotEqual(self.run_script(self.pre).returncode, 0)
        self.write_plist()
        self.env["WRONG_JOB"] = "1"
        self.assertNotEqual(self.run_script(self.pre).returncode, 0)
        self.assertEqual(self.job_state.read_text().strip(), "1")

    def test_corrupt_payload_does_not_start_daemon(self):
        state = self.existing_install()
        self.assertEqual(self.run_script(self.pre).returncode, 0)
        self.install_payload()
        (self.root / "usr/local/bin/tailscaled").write_text("corrupt")
        result = self.run_script(self.post)
        self.assertNotEqual(result.returncode, 0)
        pointer = self.root / "var/backups/tailscale-macos11-installer/pending-backup"
        self.assertTrue(pointer.is_file())
        self.assertIn(pointer.read_text().strip(), result.stderr)
        self.assertEqual(self.job_state.read_text().strip(), "0")
        self.assertEqual(state.read_text(), "identity sentinel")

    def test_bootstrap_failure_keeps_state(self):
        state = self.existing_install()
        self.assertEqual(self.run_script(self.pre).returncode, 0)
        self.install_payload()
        self.env["BOOTSTRAP_FAIL"] = "1"
        result = self.run_script(self.post)
        self.assertNotEqual(result.returncode, 0)
        pointer = self.root / "var/backups/tailscale-macos11-installer/pending-backup"
        self.assertIn(pointer.read_text().strip(), result.stderr)
        self.assertEqual(self.job_state.read_text().strip(), "0")
        self.assertEqual(state.read_text(), "identity sentinel")


if __name__ == "__main__":
    unittest.main()

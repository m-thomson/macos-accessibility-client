"""Build and test through Xcode MCP; run only the last verified app bundle."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import queue
import re
import signal
import subprocess
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "MacOSAccessibilityClient"
BUNDLE_ID = "com.nuclearcyborg.MacOSAccessibilityClient"
PROJECT = ROOT / APP_NAME / f"{APP_NAME}.xcodeproj"
RECORD = ROOT / "build/last-verified-build.json"


class Bridge:
    def __enter__(self):
        self.process = subprocess.Popen(
            ["/usr/bin/xcrun", "mcpbridge"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        self.messages = queue.Queue()
        self.request_id = 0
        threading.Thread(target=self.read_messages, daemon=True).start()
        self.request("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "Accessibility Client development helper", "version": "1"},
        })
        self.send({"method": "notifications/initialized"})
        self.request("tools/list", {})
        return self

    def read_messages(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        finally:
            self.messages.put(None)

    def send(self, message):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", **message}) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.request_id += 1
        self.send({"id": self.request_id, "method": method, "params": params})
        while True:
            try:
                message = self.messages.get(timeout=60)
            except queue.Empty:
                print("Waiting for Xcode. Check Xcode for a prompt or an unfinished operation.", flush=True)
                continue
            except KeyboardInterrupt:
                if method != "tools/call" or params.get("name") not in ("BuildProject", "RunAllTests", "RunSomeTests"):
                    raise
                print("Waiting for Xcode to finish before releasing the operation lock. Cancel in Xcode if needed.",
                      flush=True)
                continue
            if message is None:
                raise RuntimeError("Xcode MCP disconnected. Open Xcode and check its MCP access settings.")
            if message.get("id") != self.request_id:
                continue
            if "error" in message:
                raise RuntimeError(str(message["error"]))
            return message["result"]

    def call(self, name, **arguments):
        print(f"Xcode: {name}", flush=True)
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(str(result.get("content")))
        if "structuredContent" in result:
            return result["structuredContent"]
        return json.loads(next(item["text"] for item in result["content"] if item["type"] == "text"))

    def workspace(self):
        listed = self.call("XcodeListWorkspaces").get("message", "")
        workspace = next((line.split("workspaceIdentifier: ", 1)[1].split(",", 1)[0]
                          for line in listed.splitlines() if line.endswith(f"workspacePath: {PROJECT}")), None)
        if workspace is None:
            raise RuntimeError(f"Open {PROJECT} in Xcode before running development commands.")
        schemes = self.call("XcodeListSchemes", workspaceIdentifier=workspace)
        if not any(scheme["name"] == APP_NAME for scheme in schemes["schemes"]):
            raise RuntimeError("The shared application scheme is missing.")
        if schemes.get("activeSchemeName") != APP_NAME:
            self.call("XcodeSwitchScheme", workspaceIdentifier=workspace, schemeName=APP_NAME)
        destinations = self.call("XcodeListRunDestinations", workspaceIdentifier=workspace)
        if destinations.get("activeDestinationDisplayTitle") != "My Mac":
            raise RuntimeError("Select My Mac as the run destination in Xcode.")
        return workspace

    def __exit__(self, *args):
        self.process.stdin.close()
        self.process.terminate()  # Only the bridge we started; never Xcode or the app.
        self.process.wait(timeout=5)
        self.process.stdout.close()


def fingerprint(app):
    digest = hashlib.sha256()
    for path in [app, *sorted(app.rglob("*"))]:
        info = path.lstat()
        digest.update(str((path.relative_to(app), info.st_ino, info.st_mtime_ns, info.st_ctime_ns)).encode())
        if path.is_symlink():
            digest.update(os.readlink(path).encode())
        elif path.is_file():
            digest.update(path.read_bytes())
    return digest.hexdigest()


def build(bridge, workspace):
    previous = json.loads(RECORD.read_text()) if RECORD.exists() else {}
    RECORD.unlink(missing_ok=True)
    result = bridge.call("BuildProject", workspaceIdentifier=workspace)
    print(result["buildResult"], flush=True)
    print(f"Build log: {result['fullLogPath']}", flush=True)
    if result["buildResult"] != "The project built successfully." or result.get("errors"):
        raise RuntimeError(str(result.get("errors")))
    log = Path(result["fullLogPath"]).read_text()
    products = set(re.findall(
        rf"^\s+(?:CodeSign|Validate|RegisterWithLaunchServices) (/.+?/{APP_NAME}\.app)(?: \(in target|$)",
        log, re.MULTILINE,
    ))
    if not products and previous.get("app"):
        products.add(previous["app"])  # An unchanged build may have no product tasks.
    if len(products) != 1:
        raise RuntimeError("Could not identify one app in the build log. Build again after a source change.")
    app = Path(products.pop())
    with (app / "Contents/Info.plist").open("rb") as file:
        if plistlib.load(file).get("CFBundleIdentifier") != BUNDLE_ID:
            raise RuntimeError("The build returned a different application's bundle.")
    signature = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)],
                               capture_output=True, text=True, check=True)
    if "Authority=Apple Development:" not in signature.stderr:
        raise RuntimeError("The development build must use the project's Apple Development identity.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
    RECORD.parent.mkdir(exist_ok=True)
    RECORD.write_text(json.dumps({"app": str(app), "log": result["fullLogPath"], "fingerprint": fingerprint(app)}))
    print(f"Verified app: {app}", flush=True)


def running_apps():
    result = subprocess.run(["/usr/bin/pgrep", "-u", str(os.getuid()), "-x", APP_NAME],
                            capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr)
    apps = {}
    for pid in result.stdout.split():
        path = subprocess.run(["/bin/ps", "-ww", "-p", pid, "-o", "comm="], capture_output=True, text=True)
        executable = Path(path.stdout.strip())
        if path.returncode or not str(executable).endswith(f".app/Contents/MacOS/{APP_NAME}"):
            continue
        with (executable.parents[1] / "Info.plist").open("rb") as file:
            if plistlib.load(file).get("CFBundleIdentifier") == BUNDLE_ID:
                apps[int(pid)] = executable
    return apps


def stop():
    for pid in running_apps():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 15
    while running_apps():
        if time.monotonic() > deadline:
            raise RuntimeError("The app did not exit. Resolve its paused debugger or quit prompt, then retry.")
        time.sleep(0.1)
    print("Application stopped.", flush=True)


def verified_app():
    if not RECORD.exists():
        raise RuntimeError("No verified build. Run ./dev.sh build first.")
    record = json.loads(RECORD.read_text())
    app = Path(record["app"])
    if not app.is_dir() or fingerprint(app) != record["fingerprint"]:
        RECORD.unlink(missing_ok=True)
        raise RuntimeError("The verified product changed or disappeared. Run ./dev.sh build again.")
    return app


def run():
    app = verified_app()
    stop()
    verified_app()
    subprocess.run(["/usr/bin/open", str(app)], check=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        apps = running_apps()
        if len(apps) == 1 and next(iter(apps.values())) == app / "Contents/MacOS" / APP_NAME:
            print(f"Running verified app: {app} (PID {next(iter(apps))})", flush=True)
            return
        time.sleep(0.1)
    raise RuntimeError("The verified application did not stay running. Check Xcode and the app's launch alerts.")


def test(bridge, workspace, selectors):
    stop()
    RECORD.unlink(missing_ok=True)  # Tests can replace or instrument the product.
    try:
        available = bridge.call("GetTestList", workspaceIdentifier=workspace)
        if available.get("truncated"):
            raise RuntimeError("Test list was truncated; refusing to silently omit tests.")
        tests = available["tests"]
        selected = []
        for selector in selectors:
            matches = [t for t in tests if
                       (t['targetName'] + '/' + t['identifier']).startswith(selector.rstrip('/'))]
            if not matches:
                raise RuntimeError(f"No tests match {selector!r}.")
            selected.extend({"targetName": t["targetName"], "testIdentifier": t["identifier"]} for t in matches)
        if selectors:
            result = bridge.call("RunSomeTests", workspaceIdentifier=workspace, tests=selected)
        else:
            result = bridge.call("RunAllTests", workspaceIdentifier=workspace)
        print(json.dumps(result, indent=2), flush=True)
        counts = result["counts"]
        if not counts["total"] or counts["failed"] or counts["notRun"]:
            raise RuntimeError("Xcode tests did not all pass.")
    finally:
        stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["build", "test", "run", "build-and-run", "stop"])
    parser.add_argument("tests", nargs="*", help="Test target/class/method selectors for the test command")
    args = parser.parse_args()
    if args.tests and args.command != "test":
        parser.error("Test selectors are only supported by ./dev.sh test.")
    # A persistent file lets all checkouts coordinate using the same kernel lock.
    lock_path = f"/private/tmp/{BUNDLE_ID}-dev-{os.getuid()}.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another development command is active. Wait for it to finish.")
        if args.command == "stop":
            stop()
        elif args.command == "run":
            run()
        else:
            with Bridge() as bridge:
                workspace = bridge.workspace()
                if args.command == "test":
                    test(bridge, workspace, args.tests)
                else:
                    build(bridge, workspace)
                    if args.command == "build-and-run":
                        run()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))

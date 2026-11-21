#!/usr/bin/env python3
"""Stream XCTest output and bound a stalled launch separately from test runtime."""
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time


def run_xctest(command, *, startup_timeout=300, timeout=3600, report_path=None):
    started = threading.Event()
    last_test = []
    began = time.monotonic()
    process = subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                               text=True,errors='replace',bufsize=1,start_new_session=True)

    def consume():
        for line in process.stdout:
            print(line,end='',flush=True)
            if line.startswith(('Test Suite ', 'Test Case ')):
                last_test[:] = [line.strip()[:300]]
                started.set()

    reader = threading.Thread(target=consume,daemon=True)
    reader.start()

    def report(phase):
        value = dict(kind='xctest-process-progress',phase=phase,tests_started=started.is_set(),
                     elapsed_seconds=round(time.monotonic()-began,1),exit_code=process.poll(),
                     last_test=last_test[0] if last_test else None)
        if report_path:
            path = Path(report_path);path.parent.mkdir(parents=True,exist_ok=True)
            pending = path.with_suffix('.next')
            pending.write_text(json.dumps(value,indent=2)+'\n');pending.replace(path)
        return value

    def stop():
        if process.poll() is None:
            try: os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError: pass
            except PermissionError: process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError: pass
                except PermissionError: process.kill()
                process.wait(timeout=10)

    next_heartbeat = 0
    try:
        while process.poll() is None:
            elapsed = time.monotonic()-began
            if not started.is_set() and elapsed >= startup_timeout:
                stop();report('startup-timeout')
                print('XCTest never started a test suite; stopping this launch without replaying any scenario',flush=True)
                raise subprocess.TimeoutExpired(command,startup_timeout)
            if elapsed >= timeout:
                stop();report('runtime-timeout')
                raise subprocess.TimeoutExpired(command,timeout)
            if elapsed >= next_heartbeat:
                print('XCTest progress: '+json.dumps(report('running' if started.is_set() else 'waiting-for-first-test')),flush=True)
                next_heartbeat = elapsed+30
            time.sleep(min(0.1,max(0.01,startup_timeout/10)))
        reader.join(timeout=2)
        if process.returncode == 0 and not started.is_set():
            report('no-tests')
            raise RuntimeError('xcodebuild exited without starting a test suite')
        report('passed' if process.returncode == 0 else 'failed')
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode,command)
    finally:
        stop()
        reader.join(timeout=2)
        if not reader.is_alive():
            process.stdout.close()


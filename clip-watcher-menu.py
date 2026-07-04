#!/usr/bin/env python3
"""
clip-watcher menu bar app
Provides a macOS menu bar interface for clip-watcher.sh
"""

import rumps
import subprocess
import os
import threading
from pathlib import Path

# Path to clip-watcher.sh
SCRIPT_PATH = Path.home() / "scripts" / "clip-watcher.sh"

# Menu bar appearance
APP_NAME = "Clip Watcher"
ICON_RUNNING = "▶"      # Play symbol when running
ICON_STOPPED = "⏹"      # Stop symbol when stopped  
ICON_UNKNOWN = "?"       # Unknown state
ICON_STARTING = "..."    # Starting up

class ClipWatcherApp(rumps.App):
    def __init__(self):
        super().__init__(APP_NAME, quit_button=None)
        self.script_path = str(SCRIPT_PATH)
        self.update_status()
        
        # Build menu
        self.menu = [
            rumps.MenuItem("Start", callback=self.start),
            rumps.MenuItem("Stop", callback=self.stop),
            None,  # Separator
            rumps.MenuItem("Status", callback=self.status),
            rumps.MenuItem("Last Link", callback=self.last_link),
            None,  # Separator
            rumps.MenuItem("Tail Log", callback=self.tail_log),
            rumps.MenuItem("Clear Processed", callback=self.clear_processed),
            None,  # Separator
            rumps.MenuItem("Quit", callback=self.quit),
        ]
        
        # Start status update timer
        self.timer = rumps.Timer(self.update_status, 5)
        self.timer.start()
    
    def run_command(self, args, callback=None):
        """Run a clip-watcher command in background"""
        def _run():
            try:
                result = subprocess.run(
                    [self.script_path] + args,
                    capture_output=True,
                    text=True,
                    timeout=30
                )
                if callback:
                    callback(result.stdout, result.stderr, result.returncode)
            except subprocess.TimeoutExpired:
                if callback:
                    callback("", "Command timed out", 1)
            except Exception as e:
                if callback:
                    callback("", str(e), 1)
        
        threading.Thread(target=_run, daemon=True).start()
    
    def update_status(self, timer=None):
        """Update menu bar icon based on watcher status"""
        try:
            pid_file = Path.home() / "Movies" / "Captures" / "encoded" / ".clip-watcher.pid"
            if pid_file.exists():
                pid = pid_file.read_text().strip()
                # Check if process is running
                result = subprocess.run(
                    ["kill", "-0", pid],
                    capture_output=True,
                    timeout=5
                )
                if result.returncode == 0:
                    self.title = ICON_RUNNING
                    return
            self.title = ICON_STOPPED
        except Exception:
            self.title = ICON_UNKNOWN
    
    @rumps.clicked("Start")
    def start(self, _):
        def on_complete(stdout, stderr, returncode):
            if returncode == 0:
                rumps.notification("Clip Watcher", "Started", "Watcher is now running")
            else:
                rumps.notification("Clip Watcher", "Start Failed", stderr or "Check logs")
            self.update_status()
        
        self.run_command([], on_complete)
    
    @rumps.clicked("Stop")
    def stop(self, _):
        def on_complete(stdout, stderr, returncode):
            rumps.notification("Clip Watcher", "Stopped", stdout.strip() if stdout else "Watcher stopped")
            self.update_status()
        
        self.run_command(["stop"], on_complete)
    
    @rumps.clicked("Status")
    def status(self, _):
        def on_complete(stdout, stderr, returncode):
            if stdout:
                # Show status in a dialog
                rumps.alert(
                    title="Clip Watcher Status",
                    message=stdout.strip(),
                    ok="OK"
                )
            else:
                rumps.notification("Clip Watcher", "Status", stderr or "Could not get status")
        
        self.run_command(["status"], on_complete)
    
    @rumps.clicked("Last Link")
    def last_link(self, _):
        def on_complete(stdout, stderr, returncode):
            if returncode == 0 and stdout:
                # Copy to clipboard
                import subprocess
                subprocess.run(["pbcopy"], input=stdout.strip().encode(), check=True)
                rumps.notification("Clip Watcher", "Link Copied", stdout.strip())
            else:
                rumps.notification("Clip Watcher", "No Links", stderr or "No links recorded yet")
        
        self.run_command(["last"], on_complete)
    
    @rumps.clicked("Tail Log")
    def tail_log(self, _):
        log_file = Path.home() / "Movies" / "Captures" / "encoded" / "clip-watcher.log"
        if log_file.exists():
            # Open log file in default text editor
            subprocess.run(["open", "-a", "TextEdit", str(log_file)])
        else:
            rumps.notification("Clip Watcher", "No Log", "Log file not found")
    
    @rumps.clicked("Clear Processed")
    def clear_processed(self, _):
        response = rumps.alert(
            title="Clear Processed Log",
            message="This will allow all clips to be re-queued. Continue?",
            ok="Clear",
            cancel="Cancel"
        )
        if response == 1:  # OK clicked
            def on_complete(stdout, stderr, returncode):
                rumps.notification("Clip Watcher", "Cleared", "Processed log cleared")
            
            self.run_command(["clear"], on_complete)
    
    @rumps.clicked("Quit")
    def quit(self, _):
        rumps.quit_application()


if __name__ == "__main__":
    ClipWatcherApp().run()

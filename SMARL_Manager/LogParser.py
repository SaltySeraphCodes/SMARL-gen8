# Refined LogParser.py

import os, json, time
import threading
import helpers
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler


# --- I/O Utility Function ---
def readFile(fileName, max_retries=3, retry_delay=0.05):
    """
    Reads JSON data from the file with a retry mechanism to handle partial writes.
    (Existing robust logic kept here)
    """
    data = None
    for attempt in range(max_retries):
        try:
            with open(fileName, 'r') as file:
                data = json.load(file)
                return data 
        except json.JSONDecodeError:
            time.sleep(retry_delay)
        except FileNotFoundError:
            time.sleep(retry_delay)
        except Exception as e:
            print(f"Unexpected File Read Error: {type(e).__name__}: {e}")
            time.sleep(retry_delay)
    return None

DEBOUNCE_WINDOW_SECONDS = 0.1 
class ReadFileHandler(FileSystemEventHandler):
    """Handles file modification events and debounces calls to the processor."""
    
    def __init__(self, process_callback, file_to_watch):
        """Now requires the absolute path to the file it should watch."""
        self.process_callback = process_callback
        self.last_processed_time = 0
        self.file_to_watch = file_to_watch
        if not self.file_to_watch:
            print("ERROR: Handler initialized with no file path. Ignoring events.")

    def on_modified(self, event):
        if not self.file_to_watch:
            return # Skip if file path is unknown
        # Only process the exact file we care about
        if os.path.abspath(event.src_path) == os.path.abspath(self.file_to_watch):
            current_time = time.time()
            
            # Check the debounce window
            if (current_time - self.last_processed_time) > DEBOUNCE_WINDOW_SECONDS:
                
                # Execute the full processing pipeline
                self.process_callback(self.file_to_watch) # KEY CHANGE: Pass the correct file path
                
                # Update the last processed time
                self.last_processed_time = current_time

class RaceDataPoller(threading.Thread):
    """
    Dedicated thread for watching the specified race data file. 
    It finds the file path, determines the watch directory, and manages the thread.
    """
    # KEY CHANGE 1: Accept file_name as an argument
    def __init__(self, file_name, shared_state_manager):
        """
        Requires the file name (e.g., 'raceData.json') and the RaceManager instance.
        """
        super().__init__()
        self.manager = shared_state_manager 
        self.observer = Observer()
        self.stop_event = threading.Event()
        self.file_name = file_name # Store the name
        # --- Internal Path Resolution ---
        self.file_path = helpers.findFile(self.file_name)
        if not self.file_path:
            raise FileNotFoundError(f"FATAL: The file '{self.file_name}' could not be found by helpers.findFile. Check helper.py logic or file location.")
        self.file_dir = os.path.dirname(self.file_path)
        # --------------------------------

    def run(self):
        # The pipeline function called by the ReadFileHandler
        def full_pipeline(file_path):
            raw_data = readFile(file_path)
            if raw_data is None: #Guardrail
                # File read failed (e.g., all retries for partial write failed)
                #print(f"[{self.name}] Skipped processing due to failed file read or empty data.")
                return
            self.manager.process_and_broadcast_data(raw_data) 

        # Setup Watchdog: Pass the *resolved* path to the handler
        event_handler = ReadFileHandler(
            process_callback=full_pipeline, 
            file_to_watch=self.file_path 
        )
        # We tell the observer to watch the directory containing the file
        self.observer.schedule(event_handler, self.file_dir, recursive=False)
        self.observer.start()

        print(f"[{self.name}] Poller started, watching {self.file_dir} for {self.file_name}")
        
        try:
            while not self.stop_event.is_set():
                time.sleep(1) 
        finally:
            self.observer.stop()
            self.observer.join()
            print(f"[{self.name}] Poller stopped.")

    def stop(self):
        self.stop_event.set()
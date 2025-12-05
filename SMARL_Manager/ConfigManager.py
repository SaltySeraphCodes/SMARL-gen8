import json
import os

class ConfigManager:
    """Handles loading, storing, and saving application secrets and configuration."""
    
    def __init__(self, file_path='config.json'):
        self.file_path = file_path
        self.config = self._load()

    def _load(self):
        """Loads configuration data from the JSON file."""
        if not os.path.exists(self.file_path):
            print(f"Warning: {self.file_path} not found. Starting with empty config.")
            return {}
            
        try:
            with open(self.file_path, 'r') as f:
                return json.load(f)
        except Exception as e:
            print(f"Error reading {self.file_path}: {e}")
            return {}

    def save(self):
        """Saves the current configuration data back to the JSON file."""
        try:
            with open(self.file_path, 'w') as f:
                # Use indent=4 for human-readable formatting
                json.dump(self.config, f, indent=4)
            print(f"Configuration saved to {self.file_path}.")
        except Exception as e:
            print(f"Error writing to {self.file_path}: {e}")

    def get(self, key, default=None):
        """Retrieves a configuration value by key."""
        return self.config.get(key, default)

    def set(self, key, value):
        """Sets a configuration value and marks it for saving."""
        self.config[key] = value
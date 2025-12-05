import time
import json
import os
import sys
import requests 
import random
import re
import matplotlib.colors as mcolors
from typing import TYPE_CHECKING
if TYPE_CHECKING:
    import sqlite3

import shlex
from typing import List, Dict, Any, Tuple
import threading
import asyncio
from collections import deque
import asqlite
import sqlite3
from sqlite3 import dbapi2 as sqlite

import twitchio
from twitchio import eventsub
from twitchio.ext import commands
import pytchat
from queue import Queue # For thread-safe communication back to the bot
from bot_secrets import my_secrets #Todo: use configmanager.py 

debug = False
# dir_path is the current directory
dir_path = os.path.dirname(os.path.realpath(__file__))
main_path = os.path.join(dir_path,os.pardir)
realtime_path = os.path.join(main_path,"JsonData/RaceOutput/raceData.json")
# commonly use sm folder locations
json_data = os.path.join(dir_path, "Json_Data")
blueprint_base = os.path.join(dir_path, "Blueprints") #location for stored blueprints
chatter_data = os.path.join(json_data, 'chatdata.json')
sim_settings = os.path.join(json_data, 'settings.json')
# This reads Twitch/YT Chat
# Takes command /join and sends to SMARL API Server the joinCommand with data as a post request
ALL_BPS = ["typea","typeb","typec","typed"]
ALL_COLORS = [ 
        "#2926eb", # blue
        "#FF0000", # red
        "#00FF00", # green
        "#FFFFFF", # white
        "#FFFF00", # yellow
        "#000000", # black
        "#800080", # purple
        "#FFA500", # orange
        "#00008B", # darkblue
        "#FFC0CB", # pink
        "#DD1919",
        "#494949",
        "#DD4719",
        "#00FFFF", # Cyan/Aqua
        "#FF00FF", # Magenta/Fuchsia
        "#ADFF2F", # Green Yellow (or 'chartreuse')
        "#4B0082", # Indigo
        "#A52A2A", # Brown
        "#008000", # Dark Green (to contrast with the bright green)
        "#C0C0C0", # Silver/Light Gray
        "#808000", # Olive
        "#40E0D0", # Turquoise
        "#DAA520", # Goldenrod
        "#B22222", # Firebrick (a deep red/brown)
        "#5F9EA0", # Cadet Blue
        "#2F4F4F", # Dark Slate Gray
        "#9932CC", # Dark Orchid
        "#FF7F50", # Coral
    ] 


CSS4_COLORS = mcolors.CSS4_COLORS
XKCD_COLORS = {k.split(':')[-1]: v for k, v in mcolors.XKCD_COLORS.items()}


def isHexColor(color_string: str) -> bool:
    """
    Checks if a string is a 6-digit hex code (e.g., #RRGGBB) or a known color name.
    """
    hex_pattern = r'^#[0-9a-fA-F]{6}$'
    if re.fullmatch(hex_pattern, color_string):
        return True
    return False

def getHexColor(color_string:str) -> str | None:
    """
    Inputs a named color string and outputs the matching hex code.
    checking against both CSS4 and XKCD color names.
    """
    key = color_string.lower()
    # 1. Check Standard CSS4 Colors (148 colors)
    hex_code = CSS4_COLORS.get(key)
    if hex_code is not None:
        return hex_code
    # 2. Check Expanded XKCD Colors (~949 colors)
    hex_code = XKCD_COLORS.get(key)
    if hex_code is not None:
        return hex_code
    # 3. No Match
    return None

def getRandomColor(): # Gets random color from all colors
    """Gets a random color from the predefined ALL_COLORS list."""
    return random.choice(ALL_COLORS)

def getRandomBody(): # Can use logic to reduce chance of certain bodies?
    return random.choice(ALL_BPS)


SETTINGS = {
    'debug': False, # Allows unlimited entry for a single user
    'showChats': True,
    'allFree': True, # make everything freee
    'sponsorFree': True, # channel Members get free commands
    'fixedCost': 0, # if >0 and allFree == false, all commands will cost this price
    'interval': 1, # rate in which to check for new commands, BROKEN until fixed...
    'prefixes': ['!','/','$','%'],
    'filename': os.path.join(json_data, 'streamchat.json'),
    
    # --- STREAM PLATFORM SETTINGS ---
    'STREAM_PLATFORM': 'twitch', # <-- Set to 'twitch' to switch platforms
    'youtube_stream_url': "FFZWwK1y3fI", #<-- Update this to your youtube stream url ID
    'twitch_stream_url': "ccscrapracingleague", # <- Update this to your twitch 
    # --------------------------------
    
    'commands': { # list of commands and parameters, their prices are the values
        'join': 0, # Adds car to race (if entries are open)
        'save': 0, # Saves car as user's preffered car (TODO)
        'leave': 0, # LEaves race (if entries are open)
        'open': 0,
        'close': 0,
        'start': 0,
        'reset': 0,
        'refund': 0,
    },
    'single': ['save','leave','open','close','start','reset','refund'], # list of all single param commands for extra validation
    'capacity': 10, # Capacity of racers in a track (Set in appplication.py this is redundant)
    'entries_open' : False,
    'Binterval': 0.2, # Sleep interval between batches of chats
    'Cinterval': 0.2, # Sleep interval between Each Chat
}


# Define this at the top of your file, near SETTINGS
COMMAND_VALIDATION_MAP = {
    "join": {
        "user_must_be_in_race": False,# User must NOT be in the race to join
        "entries_must_be_open": True, # Entries must be open
        "error_user_check": "User already in Race",
        "error_entries_check": "Entries Are closed"
        
    },
    "leave": {
        "user_must_be_in_race": True, # User MUST be in the race to leave
        "entries_must_be_open": True, # Entries must be open to leave (as per original logic)
        "error_user_check": "User Not in Race",
        "error_entries_check": "Can't leave a closed race"
    },
    "save": {
        "user_must_be_in_race": True,# User MUST be in the race to save their car
        "entries_must_be_open": None, # Doesn't matter if entries are open
        "error_user_check": "User Not in Race",
        "error_entries_check": None
    },
    "open":{
        "user_is_moderator": True, # User needs to be a moderator
        "error_moderator_check": "User Not a Moderator",
    },
    "close":{
        "user_is_moderator": True, # User needs to be a moderator
        "error_moderator_check": "User Not a Moderator",
    },
    "start":{
        "user_is_moderator": True, # User needs to be a moderator
        "error_moderator_check": "User Not a Moderator",
    },
    "reset":{
        "user_is_moderator": True, # User needs to be a moderator
        "error_moderator_check": "User Not a Moderator",
    },
    "refund":{
        "user_is_moderator": True, # User needs to be a moderator
        "error_moderator_check": "User Not a Moderator",
    }
    # Add other commands here
}
  



def validatePayment(command: str, price: int, message: Dict[str, Any]) -> bool:
    # Validate payment data for the specified command
    if command != None: 
        if SETTINGS['allFree'] or (SETTINGS['sponsorFree'] and message['sponsor']) or ((SETTINGS['fixedCost'] >0 and message['amount'] >= SETTINGS['fixedCost']) or message['amount'] >= price) :
            return True
        elif message['amount'] < price:
            print(f"Insuficcient payment: {message['amount']} < {price}")
            return False
        else:
            print("Payment Failed")
            return False
    return False

def checkEntered(joinedChatters: List[Dict[str, Any]], key: str, value: str) -> bool:
    if SETTINGS['debug']:
        return False
    for racer in joinedChatters:
        if racer.get(key,False) == value:
            return True
    return False

def check_moderator(user):
    return user['moderator']

def change_entry_status(state): # Opens/closes entries
    global SETTINGS
    SETTINGS['entries_open'] = state

def validateCommand(command: str, parameters: List[str], parsed: Dict, joinedChatters: List[Dict[str, Any]]) -> Tuple[str | bool, str | int | None, int | None]: 
    """
    Validates a command against user status, race status, and required price.
    Returns (comType, price) or (False, errorType).
    """
    comType = str(command)
    price = None

    # 1. Check if the command itself is valid
    if comType not in SETTINGS['commands']:
        return False, "Command Invalid"
    
    # 2. Check race capacity and update settings (Initial capacity check)
    current_racers = len(joinedChatters)
    if current_racers >= SETTINGS['capacity']:
        change_entry_status(False)
        
        
        
    
    # Get the specific validation rules for this command
    validation_rules = COMMAND_VALIDATION_MAP.get(comType)

    if validation_rules:
        # Check 1: User Status (In or Out of Race)
        user_in_race = checkEntered(joinedChatters, 'uid', parsed['userid'])
        is_moderator = check_moderator(parsed)
        entries_open = SETTINGS.get('entries_open', False)

        # If the requirement (True or False) doesn't match the reality (user_in_race)
        required_status = validation_rules.get("user_must_be_in_race")
        if required_status is not None and user_in_race != required_status:
            return False, validation_rules["error_user_check"]

        # Check 2: Entries Open Status
        required_entries_status = validation_rules.get("entries_must_be_open")
        
        # If entries must be open/closed and the current status doesn't match
        if required_entries_status is not None and entries_open != required_entries_status:
            return False, validation_rules["error_entries_check"]
        
        # Check 3: User is a moderator
        required_status = validation_rules.get("user_is_moderator")
        if required_status is not None and is_moderator != required_status:
            return False, validation_rules["error_moderator_check"]


    # 3. Parameter Count and Price (Original logic, simplified)
    
    price = SETTINGS['commands'][comType]
    
    # Simple price validation for single-param or non-join commands
    # This block also captures the price for 'join' (which is 0 in your settings)
    return comType, price

def smart_split(command_line: str) -> List[str]:
    """
    Splits a command line string into a list of arguments, respecting quotes.
    e.g., 'join "vomit green" #FF0000' -> ['join', 'vomit green', '#FF0000']
    """
    try:
        # shlex.split is the most reliable way to handle quoted parameters
        return shlex.split(command_line)
    except ValueError as e:
        # Handle cases where quotes aren't properly closed
        print(f"Error parsing command with quotes: {e}")
        # Fallback to simple split if parsing fails
        return command_line.split()

def parse_join_params(params: List[str]) -> Tuple[str, str, str, str]:
    """
    Parses the command parameters for body type and colors.
    """
    body_type = "saved"
    colors_to_fill = []
    
    # Separate body type and potential colors
    for param in params:
        param_lower = param.lower()
        
        # 1. Check for Body Type
        if param_lower.startswith("type"):
            if param_lower in ALL_BPS:
                body_type = param_lower
            else:
                # If invalid type, it falls back to the default "typea"
                pass 
                
        # 2. Check for Color
        else:
            hex_color = None
            # Check if it's a valid hex color
            if isHexColor(param):
                hex_color = param
            # Check if it's a valid named color
            else:
                hex_color = getHexColor(param) 
            if hex_color:
                if body_type == "saved":
                    body_type = "typea" # TODO: select a random choice from ALL_BPs # This might nott be necessary since this is done in RaceManager Server Side
                colors_to_fill.append(hex_color)

    # 3. Apply Colors and Defaults
    
    # Initialize the three color slots
    primary = "#FFFFFF" # Use a neutral default instead of 'def'
    secondary = "#FFFFFF"
    tertiary = "#222222" # Fixed dark color

    # Unpack the found colors, filling up to the first three slots
    if len(colors_to_fill) >= 1:
        primary = colors_to_fill[0]
    if len(colors_to_fill) >= 2:
        secondary = colors_to_fill[1]
    
    # Fill remaining slots with random colors if not provided
    if len(colors_to_fill) < 1:
        primary = getRandomColor()
    if len(colors_to_fill) < 2:
        secondary = getRandomColor()
    
    if len(colors_to_fill) >= 3:
        tertiary = colors_to_fill[2]
    
    return body_type, primary, secondary, tertiary

# ---------------------------------------------
MAX_LOAD_RETRIES = 5
RETRY_DELAY_SECONDS = 0.05
class ChatCommandProcessor:
    def __init__(self, settings: Dict[str, Any], test_mode: bool = False,response_queue: Queue = None):
        # Initial State (will be dynamically updated in readChat/process_message)
        self.SETTINGS = settings
        self.is_test_mode = test_mode
        self.cID = 0
        self.joinedChatters: List[Dict[str, Any]] = [] # list of userIDs of chatters currently spawned
        self.simSettings: Dict[str, Any] = {} # settings loaded from sim_settings.json
        self.response_queue = response_queue
        self.reset_state()
        
    def reset_state(self):
        """Resets the transient state for a new test run or loop iteration."""
        self.cID = 0
        self.joinedChatters = []
        # Load initial settings from file or use default for tests
        if not self.is_test_mode:
            self._load_current_state()
        else:
            self.simSettings = {"entries_open": self.SETTINGS.get('entries_open', True)}


    def _load_current_state(self):
        """Loads joinedChatters and simSettings from JSON files (used in production loop)."""
        # --- Load realtime_path (joinedChatters and main state) ---
        # Initialize data to a default empty dict
        data = {} 
        for attempt in range(MAX_LOAD_RETRIES):
            try:
                # 1. Open and read the raw content
                with open(realtime_path, 'r', encoding='utf-8') as f:
                    raw_content = f.read()
                # 2. Check for empty content
                if not raw_content.strip():
                    # If empty, use default data and exit the retry loop
                    self.joinedChatters = []
                    data = {} 
                    break 
                # 3. Attempt to decode the JSON
                data = json.loads(raw_content) 
                # If decoding is successful, exit the retry loop
                self.joinedChatters = data.get('rt', []) or []
                break 
            except json.JSONDecodeError as e:
                # This is the expected error when the file is partially written
                if attempt < MAX_LOAD_RETRIES - 1:
                    #print(f"Warning: JSONDecodeError on attempt {attempt + 1}. Retrying in {RETRY_DELAY_SECONDS}s.")
                    # Wait briefly before retrying
                    time.sleep(RETRY_DELAY_SECONDS) 
                else:
                    # After all retries fail, log the error and use defaults
                    print(f"FATAL JSON ERROR: Failed to parse {realtime_path} after {MAX_LOAD_RETRIES} attempts.")
                    print(f"Error: {e}. Raw content preview: {raw_content[:100]}...")
                    self.joinedChatters = []
                    data = {} # Ensure data is reset before moving on
                    # We will NOT raise the error here, as that would crash the thread.
            except FileNotFoundError:
                print(f"Warning: File not found {realtime_path}. Using empty list.")
                self.joinedChatters = []
                data = {}
                break # Exit loop if file doesn't exist
        # --- Load sim_settings (simSettings) ---
        # Keep this section as-is, but you may want to apply a similar retry logic if 
        # that file is also written by the game. If it's static, the current logic is fine.
        try:
            with open(sim_settings, 'r') as sinFile: 
                self.simSettings = json.load(sinFile)
                sim_entries_open = self.simSettings.get('entries_open', True)

                if sim_entries_open != self.SETTINGS['entries_open']:
                    print(f"[{'Opening' if sim_entries_open else 'Closing'} Entries]")
                    self.SETTINGS['entries_open'] = sim_entries_open
                    change_entry_status(sim_entries_open)

        except (FileNotFoundError, json.JSONDecodeError):
            print(f"Warning: Could not read {sim_settings}. Using last settings.")
            #self.simSettings = {}


    def send_twitch_response(self, message: str):
        """Puts a message into the outgoing queue if Twitch is active."""
        if self.SETTINGS['STREAM_PLATFORM'].lower() == 'twitch' and self.response_queue:
            self.response_queue.put(message)

    # --- API Request Methods (Remain largely the same, but now methods) ---
    def send_join_request(self, command: Dict[str, Any]) -> bool:
        # 1. Eligibility Check (using self.simSettings)
        if not self.simSettings.get('entries_open', True):
            print(f"Join rejected for {command['username']}: Entries closed locally.")
            return False
            
        # 2. Parse Parameters 
        body_type, primary, secondary, tertiary = parse_join_params(command['params'])

        # 3. Construct Payload 
        url = "http://localhost:5056/api/join_twitch_race"
        payload = {
            "username": command['username'],
            "userid": command['userid'],
            "bp": body_type,
            'is_bot': False,
            "colors": f"{primary},{secondary},{tertiary}"
        }

        # 4. Send API Request and Handle Response
        try:
            response = requests.post(url, json=payload, timeout=3)
            if response.status_code == 200:
                # This is a simplification for testing; in production, this is usually loaded from file.
                self.send_twitch_response(
                    f"@{command['username']}, you have successfully joined the race!"
                )
                if self.is_test_mode:
                     # Add a mock entry to mimic the file-read logic Can still run/test even if not, just will try to ping SM)
                     self.joinedChatters.append({'uid': command['userid'], 'username': command['username']}) 
                     
                print(f" Join SUCCESS for {command['username']}.")
                return True
                # Denied Action: 403 Forbidden (RaceManager denied entry)
            elif response.status_code == 403:
                # Parse the JSON response body for the specific denial reason
                try:
                    data = response.json()
                    reason = data.get('message', 'Entries closed by server.')
                    self.send_twitch_response(
                        f"@{command['username']}, your join request was denied: {reason}"
                    )
                    print(f" Join DENIED for {command['username']}. Reason: {reason}")
                except json.JSONDecodeError:
                    print(f" Join DENIED for {command['username']}. (Could not parse error response).")
                return False
            
            # Client/Server Errors: 400s or 500s
            else:
                try:
                    data = response.json()
                    error_msg = data.get('error', response.text)
                    print(f" Join FAILED for {command['username']} (Status {response.status_code}). Error: {error_msg}")
                except json.JSONDecodeError:
                    print(f"Join FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False

        except requests.exceptions.ConnectionError:
            print(f" Error: Could not connect to API server at {url}. Is RaceManager running?")
            return False
        except requests.exceptions.RequestException as e:
            print(f" An error occurred sending join request: {e}")
            return False

    def send_save_request(self, command: Dict[str, Any]) -> bool:
        url = "http://localhost:5056/api/save_twitch_car"
        bp_param = command['params'][0] if command.get('params') and len(command['params']) > 0 else None
        colors_param = command['params'][1] if command.get('params') and len(command['params']) > 1 else None
        
        payload = {
            "username": command['username'], 
            "userid": command['userid'], 
            "bp": bp_param, 
            "colors": colors_param
        } 
        try:
            response = requests.post(url, json=payload, timeout=3)
            
            if response.status_code == 200:
                self.send_twitch_response(
                    f"@{command['username']}, your car settings have been saved!"
                )
                print(f"Save SUCCESS for {command['username']}.")
                return True
            else:
                # Handle client/server errors (400, 500)
                try:
                    data = response.json()
                    error_msg = data.get('message', response.text)
                    self.send_twitch_response(
                        f"@{command['username']}, failed to save: {error_msg}"
                    )
                    print(f"Save FAILED for {command['username']} (Status {response.status_code}). Message: {error_msg}")
                except json.JSONDecodeError:
                    print(f"Save FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"Failed to send 'save' request: {e}")
            return False
            
        
    def send_leave_request(self, command: Dict[str, Any]) -> bool:
        """Sends a request to the API to remove the racer associated with the user."""
        url = "http://localhost:5056/api/leave_twitch_race" # Assuming this is the correct endpoint
        
        payload = {
            "username": command['username'], 
            "userid": command['userid'], 
        } 

        try:
            response = requests.post(url, json=payload, timeout=3)
            
            if response.status_code == 200:
                self.send_twitch_response(
                    f"@{command['username']}, you have successfully left the race."
                )
                print(f" Leave SUCCESS for {command['username']}.")
                
                if self.is_test_mode or True: # Force update for simplicity
                    self.joinedChatters = [
                        racer for racer in self.joinedChatters 
                        if racer['uid'] != command['userid']
                    ]
                return True
            else:
                # Handle errors (400, 500)
                try:
                    data = response.json()
                    error_msg = data.get('message', response.text)
                    self.send_twitch_response(
                        f"@{command['username']}, unable to leave: {error_msg}"
                    )
                    print(f" Leave FAILED for {command['username']} (Status {response.status_code}). Message: {error_msg}")
                except json.JSONDecodeError:
                    print(f"Leave FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"Failed to send 'leave' request: {e}")
            return False

    
    def send_open_request(self, command: Dict[str, Any]) -> bool:
        """Sends a request to the API to Open Twitch Entries (Admin command)."""
        url = "http://localhost:5056/api/open_twitch_entries"
        
        payload = {
            "username": command['username'], 
            "userid": command['userid'], 
        } 

        try:
            response = requests.get(url, json=payload, timeout=3)
            
            if response.status_code == 200:
                self.send_twitch_response(
                    f"@{command['username']}, Opening Race Entries."
                )
                print(f" Admin Opened Race {command['username']}.")
                
            else:
                # Handle errors (400, 500)
                try:
                    data = response.json()
                    error_msg = data.get('message', response.text)
                    self.send_twitch_response(
                        f"@{command['username']}, unable to Open: {error_msg}"
                    )
                    print(f" Open FAILED for {command['username']} (Status {response.status_code}). Message: {error_msg}")
                except json.JSONDecodeError:
                    print(f"Open FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"Failed to send 'open' request: {e}")
            return False

    def send_close_request(self, command: Dict[str, Any]) -> bool:
        """Sends a request to the API to Close Twitch Entries (Admin command)."""
        url = "http://localhost:5056/api/close_twitch_entries"
        
        payload = {
            "username": command['username'], 
            "userid": command['userid'], 
        } 

        try:
            response = requests.get(url, json=payload, timeout=3)
            
            if response.status_code == 200:
                self.send_twitch_response(
                    f"@{command['username']}, Closing Race Entries."
                )
                print(f" Admin Closed Race {command['username']}.")
                
            else:
                # Handle errors (400, 500)
                try:
                    data = response.json()
                    error_msg = data.get('message', response.text)
                    self.send_twitch_response(
                        f"@{command['username']}, unable to Close: {error_msg}"
                    )
                    print(f" Close FAILED for {command['username']} (Status {response.status_code}). Message: {error_msg}")
                except json.JSONDecodeError:
                    print(f"Close FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"Failed to send 'close' request: {e}")
            return False
    
    def send_start_request(self, command: Dict[str, Any]) -> bool:
        """Sends a request to the API to Start Twitch Race (Admin command)."""
        url = "http://localhost:5056/api/start_twitch_race"
        
        try:
            response = requests.get(url, timeout=10)
            
            if response.status_code == 200:
                self.send_twitch_response(
                    f"@{command['username']}, Startin Race!"
                )
                print(f" Admin Started Race {command['username']}.")
                
            else:
                # Handle errors (400, 500)
                try:
                    data = response.json()
                    error_msg = data.get('message', response.text)
                    self.send_twitch_response(
                        f"@{command['username']}, unable to Start: {error_msg}"
                    )
                    print(f" Start FAILED for {command['username']} (Status {response.status_code}). Message: {error_msg}")
                except json.JSONDecodeError:
                    print(f"Start FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"Failed to send 'start' request: {e}")
            return False

    def send_reset_request(self, command: Dict[str, Any]) -> bool:
        """Sends a request to the API to reset Twitch Race (Admin command)."""
        url = "http://localhost:5056/api/reset_twitch_race"
        
        payload = {
            "username": command['username'], 
            "userid": command['userid'], 
        } 

        try:
            response = requests.get(url, json=payload, timeout=10)
            
            if response.status_code == 200:
                self.send_twitch_response(
                    f"@{command['username']}, Resetting Race."
                )
                print(f" Admin reset Race {command['username']}.")
                
            else:
                # Handle errors (400, 500)
                try:
                    data = response.json()
                    error_msg = data.get('message', response.text)
                    self.send_twitch_response(
                        f"@{command['username']}, unable to reset: {error_msg}"
                    )
                    print(f" Reset FAILED for {command['username']} (Status {response.status_code}). Message: {error_msg}")
                except json.JSONDecodeError:
                    print(f" Reset FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"Failed to send 'resey' request: {e}")
            return False

    def send_reset_laps_request(self, command: Dict[str, Any]) -> bool:
        """Sends a request to the API to reset Twitch Stats/Laps (Admin command)."""
        url = "http://localhost:5056/api/reset_twitch_laps"
        
        payload = {
            "username": command['username'], 
            "userid": command['userid'], 
        } 

        try:
            response = requests.get(url, json=payload, timeout=3)
            
            if response.status_code == 200:
                self.send_twitch_response(
                    f"@{command['username']}, Resetting Best Lap times."
                )
                print(f" Admin reset best laps {command['username']}.")
                
            else:
                # Handle errors (400, 500)
                try:
                    data = response.json()
                    error_msg = data.get('message', response.text)
                    self.send_twitch_response(
                        f"@{command['username']}, unable to reset laps: {error_msg}"
                    )
                    print(f" Reset Laps FAILED for {command['username']} (Status {response.status_code}). Message: {error_msg}")
                except json.JSONDecodeError:
                    print(f" Reset laps FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"Failed to send 'resey' request: {e}")
            return False

    def send_reset_season_request(self, command: Dict[str, Any]) -> bool:
        """Sends a request to the API to reset Twitch Season Stats (Admin command)."""
        url = "http://localhost:5056/api/reset_twitch_season"
        
        payload = {
            "username": command['username'], 
            "userid": command['userid'], 
        } 

        try:
            response = requests.get(url, json=payload, timeout=3)
            
            if response.status_code == 200:
                self.send_twitch_response(
                    f"@{command['username']}, Resetting Twitch Season."
                )
                print(f" Admin reset twitch season {command['username']}.")
                
            else:
                # Handle errors (400, 500)
                try:
                    data = response.json()
                    error_msg = data.get('message', response.text)
                    self.send_twitch_response(
                        f"@{command['username']}, unable to reset season: {error_msg}"
                    )
                    print(f" Reset Season FAILED for {command['username']} (Status {response.status_code}). Message: {error_msg}")
                except json.JSONDecodeError:
                    print(f" Reset Season FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"Failed to send 'reset season' request: {e}")
            return False

    def send_predictions_toggle(self, command: Dict[str, Any]) -> bool:
        """Sends a request to the API to enable/disable predictions (Admin command)."""
        url = "http://localhost:5056/api/set_predictions_enabled"

        try:
            response = requests.get(url, timeout=3)
            
            if response.status_code == 200:
                self.send_twitch_response(
                    f"@{command['username']}, Refund Twitch Prediction."
                )
                print(f" Admin Refund Twitch Prediction {command['username']}.")
                
            else:
                # Handle errors (400, 500)
                try:
                    data = response.json()
                    error_msg = data.get('message', response.text)
                    self.send_twitch_response(
                        f"@{command['username']}, unable to Refund: {error_msg}"
                    )
                    print(f" Refund FAILED for {command['username']} (Status {response.status_code}). Message: {error_msg}")
                except json.JSONDecodeError:
                    print(f" Refund FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"Failed to send 'Refund' request: {e}")
            return False

    def send_refund_request(self, command: Dict[str, Any]) -> bool:
        """Sends a request to the API to refund current prediction (Admin command)."""
        url = "http://localhost:5056/api/refund_twitch_prediction"
        
        payload = {
            "username": command['username'], 
            "userid": command['userid'], 
        } 

        try:
            response = requests.get(url, json=payload, timeout=3)
            
            if response.status_code == 200:
                self.send_twitch_response(
                    f"@{command['username']}, Refund Twitch Prediction."
                )
                print(f" Admin Refund Twitch Prediction {command['username']}.")
                
            else:
                # Handle errors (400, 500)
                try:
                    data = response.json()
                    error_msg = data.get('message', response.text)
                    self.send_twitch_response(
                        f"@{command['username']}, unable to Refund: {error_msg}"
                    )
                    print(f" Refund FAILED for {command['username']} (Status {response.status_code}). Message: {error_msg}")
                except json.JSONDecodeError:
                    print(f" Refund FAILED for {command['username']} (Status {response.status_code}). Server returned non-JSON error.")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"Failed to send 'Refund' request: {e}")
            return False


    # --- Command Handling (Now methods of the class) ---
    def handleCommand(self, command: Dict[str, Any]):
        """Delegates the command based on type."""
        if command['type'] == "join":
            self.send_join_request(command)
        elif command['type'] == "save":
            self.send_save_request(command)
        elif command['type'] == "leave":
            self.send_leave_request(command)
        elif command['type'] == "open":
            self.send_open_request(command)
        elif command['type'] == "close":
            self.send_close_request(command)
        elif command['type'] == "start":
            self.send_start_request(command)
        elif command['type'] == "reset":
            self.send_reset_request(command)
        elif command['type'] == "resetlaps":
            self.send_reset_laps_request(command)
        elif command['type'] == "resetseason":
            self.send_reset_season_request(command)
        elif command['type'] == "refund":
            self.send_refund_request(command)

    def generateCommand(self, command: str, parameters: List[str], cmdData: Dict[str, Any]) -> Dict[str, Any]:
        """Generates the command dictionary (same as original function)."""
        return {'id': cmdData['id'], 'type':command, 'params':parameters, 'username': cmdData['author'], 
                'sponsor': cmdData['sponsor'], 'userid': cmdData['userid'], 'amount': cmdData['amount']}

    def parseMessage(self, chat_item: Any, mesID: int) -> Dict[str, Any] | None:
        """
        Parses an incoming chat message for a command and its parameters.
        This is the new *target function* for injection.
        """
        # 1. Initial Parsing and Cleanup 
        message_text = chat_item['message'].lower().strip() # Adapt from pytchat to dict
        author_data = chat_item.get('author',{}) # User/channel specific data such as userid and status
        # Create the initial message dictionary (Adapted for generic dict input)
        parsed = {
            'id': mesID, 
            'command_text': message_text, 
            'author': author_data['name'], 
            'sponsor': author_data.get('isChatSponsor', False),
            'moderator': author_data.get('isChatModerator', False), 
            'userid': author_data['channelId'], 
            'amount': chat_item.get('amountValue', 0.0), 
            'timestamp': chat_item.get('timestamp', time.time())
        }

        # 2. Command Check (same as original)
        allowed_prefixes = self.SETTINGS.get('prefixes', ['!']) 
        is_command = any(message_text.startswith(p) for p in allowed_prefixes)
        if not message_text or not is_command:
            return None 

        used_prefix = next(p for p in allowed_prefixes if message_text.startswith(p))
        raw_command_text = message_text.lstrip(used_prefix).strip()
        if not raw_command_text:
            return None

        # 3. Parameter Extraction
        split_tokens = smart_split(raw_command_text)
        if not split_tokens:
            return None
            
        command_name = split_tokens[0]
        params_list = split_tokens[1:]

        # 4. Command Validation (using instance attributes)
        comType, price = validateCommand(command_name, params_list, parsed, self.joinedChatters)
        
        if comType is False:
            print(f"Received Error for '{raw_command_text}': {price}") 
            return None

        # 5. Payment Validation and Final Command Generation
        validPayment = validatePayment(comType, price, parsed)
        if validPayment:
            command = self.generateCommand(comType, params_list, parsed)
            return command
        else:
            print("Invalid Payment")
            return None

    def process_incoming_chat(self, chat_item: Dict[str, Any]):
        """
        The public method that the injector will call. 
        It increments the message ID and handles the command lifecycle.
        """
        if not self.is_test_mode: # How does this work?
            # In production, we'd load state here too, but in a loop it's done in readChat
            # For injection, we assume state is managed by the injector if needed.
            pass
        command = self.parseMessage(chat_item, self.cID)
        self.cID += 1
        
        if command is not None:
            self.handleCommand(command)

def readChat(chat_reader: Any, processor: ChatCommandProcessor) -> bool: 
    """Reads incoming chat items from the provided reader object and processes commands."""
    
    if not chat_reader:
        print("Error: Chat reader is None.")
        return False
        
    while chat_reader.is_alive():
        # --- Load state once per batch (Delegated to processor) ---
        # This updates processor.joinedChatters and processor.simSettings
        processor._load_current_state() 
        # --- End Load State ---
        # Process all new messages in the batch
        for c in chat_reader.get().sync_items():
            try:
                # Convert the JSON string (c.json()) into a Python dictionary
                chat_dict = json.loads(c.json()) 
                processor.process_incoming_chat(chat_dict)
            except AttributeError:
                # Handle cases where c.json() might not exist or c is already a dict/str
                # If pytchat's item c *already* provides a dict, this may need adjustment.
                # However, based on the error, c.json() returns a string.
                print("Warning: Failed to call .json() or load JSON from chat item.")
                # Proceed with c assuming it might be the dict already (fallback)
                processor.process_incoming_chat(c) 
            except json.JSONDecodeError:
                print("Error: Could not decode JSON from chat item.")
                continue # Skip this message
            
        try:
            chat_reader.raise_for_status()
        except Exception as e:
            print("Got chat exception",type(e), str(e))
            break
            
    print("readChat loop broke out")
    return False


# End general command processing
def setup_database(db) -> tuple[list[tuple[str, str]], list[eventsub.SubscriptionPayload]]: # This might need to be removed
        # Create our token table, if it doesn't exist..
        # You should add the created files to .gitignore or potentially store them somewhere safer
        # This is just for example purposes...

        query = """CREATE TABLE IF NOT EXISTS tokens(user_id TEXT PRIMARY KEY, token TEXT NOT NULL, refresh TEXT NOT NULL)"""
        with db as connection:
            cursor = connection.cursor()
            cursor.execute(query)

            # Fetch any existing tokens...
            cursor.execute("""SELECT * from tokens""")
            rows: list[sqlite3.Row] = cursor.fetchall()

            tokens: list[tuple[str, str]] = []
            subs: list[eventsub.SubscriptionPayload] = []

            for row in rows:
                tokens.append((row["token"], row["refresh"]))


        return tokens, subs


# 1. Custom Chat Class (to mimic pytchat's output structure)
class TwitchChatItem:
    """A simplified structure to match the attributes expected by parseMessage()"""
    def __init__(self, message_payload, author_name, author_id, tags):
        self.message = message_payload.text  # <--- Change this line to use .text        self.timestamp = str(message.timestamp)
        self.amountValue = 0.0 # Bits/Cheer is complex; set to 0 for simplicity
        self.timestamp = str(message_payload.timestamp) 
    
        # Create a nested object structure to match pytchat/YouTube
        class Author:
            def __init__(self, name, id, tags):
                self.name = name
                self.channelId = id
                # Use standard Twitch badges for 'sponsor' eligibility
                self.isChatSponsor = tags.get('mod', False) or tags.get('subscriber', False) or tags.get('vip', False)
                self.isChatModerator = tags.get('mod', False)
        
        # NOTE: The nested structure requires a slight adjustment here for consistency with your JSON/parsing later
        class SimpleAuthor:
            def __init__(self, author_name, author_id, tags):
                self.name = author_name
                self.channelId = author_id
                self.isChatSponsor = tags.get('mod', False) or tags.get('subscriber', False) or tags.get('vip', False)
                self.isChatModerator = tags.get('mod', False)

        # We will use SimpleAuthor directly to avoid deep nesting issues
        self.author = SimpleAuthor(author_name, author_id, tags)

    def json(self) -> str:
        """Mimics pytchat's .json() to return a serializable dict."""
        return json.dumps({
            'message': self.message,
            'timestamp': self.timestamp, # <--- Timestamp is now included
            'amountValue': self.amountValue,
            'author': {
                'name': self.author.name,
                'channelId': self.author.channelId,
                'isChatSponsor': self.author.isChatSponsor,
                'isChatModerator': self.author.isChatModerator,
            }
        })


# command examples



# 2. Main Twitch Bot/Client (Handles events)
class TwitchReaderBot(commands.AutoBot):
    """The asynchronous bot that handles Twitch events."""
    # Updated __init__
    def __init__(self, channel_name, reader_queue, response_queue,loop,token_db,tokens):
        self.loop = loop
        self.nick = "CCScrapRacingBot "
        self.client_id = my_secrets['client_id']
        self.client_secret = my_secrets['client_secret']
        self.channel_name = channel_name.lstrip('#')
        self.token_database = token_db
        for pair in tokens:
            self.add_token(*pair)
        
        # Define the necessary IDs locally to use in super().__init__
        auth_token = my_secrets['oauth_token']
        bot_id = my_secrets['bot_id']
        owner_id = my_secrets['owner_id']
        broadcaster_id = my_secrets['owner_id']

        chat_sub = eventsub.ChatMessageSubscription(
            broadcaster_user_id=broadcaster_id, 
            user_id=bot_id
        )
        super().__init__(
            token=auth_token,
            client_id=self.client_id,
            client_secret=self.client_secret,
            bot_id=bot_id,
            owner_id=owner_id,
            prefix=SETTINGS.get('prefixes', ['!'])[0], # Use the first prefix as the bot's command prefix
            subscriptions=[chat_sub], # List of required subscriptions
            force_subscribe=True,     # Forces a resubscribe on startup if needed
        )
        self.reader_queue = reader_queue
        self.response_queue = response_queue # New Queue for outgoing messages
        self.is_running = True
        self.channel_name = channel_name.lstrip('#')
        # Add a loop task to constantly check the response queue
        self.response_task = None 

    async def setup_hook(self) -> None:
        # Add our component which contains our commands...
        await self.add_component(MyComponent(self))

    async def event_oauth_authorized(self, payload: twitchio.authentication.UserTokenPayload) -> None:
        await self.add_token(payload.access_token, payload.refresh_token)

        if not payload.user_id:
            return

        if payload.user_id == self.bot_id:
            # We usually don't want subscribe to events on the bots channel...
            return

    async def add_token(self, token: str, refresh: str) -> twitchio.authentication.ValidateTokenPayload:
        # Make sure to call super() as it will add the tokens interally and return us some data...
        resp: twitchio.authentication.ValidateTokenPayload = await super().add_token(token, refresh)
        # Store our tokens in a simple SQLite Database when they are authorized...
        query = """
        INSERT INTO tokens (user_id, token, refresh)
        VALUES (?, ?, ?)
        ON CONFLICT(user_id)
        DO UPDATE SET
            token = excluded.token,
            refresh = excluded.refresh;
        """

        #with self.token_database.acquire() as connection: #TODO: fix this to be cursor
        #    connection.execute(query, (resp.user_id, token, refresh))
        #print("precurs")
        #curs = await self.token_database.cursor()
        #print('postget',curs)
        #with self.token_database as connection: # doube check if db or connection is passed through
        #    print('pre curs',connection,dir(connection))
        #    cursor = connection.cursor()
        #    print("got curs",cursor)
        #   cursor.execute(query,(resp.user_id, token, refresh))
        #    print("post curs")
        #print("post db")

        print("Added token to the database for user: %s", resp.user_id)
        return resp

    async def event_ready(self):
        print(f'Twitch Bot logged in as | {self.nick}')
        print(f'Joining channel: #{self.channel_name}')
        # Start the background task to check for outgoing messages
        self.response_task = self.loop.create_task(self.check_response_queue())
    
    async def check_response_queue(self):
        """Asynchronously checks the response queue and sends messages."""
        await self.wait_for_ready()
        
        # Get the channel object once for efficiency
        channel = self.get_channel(self.channel_name)
        if not channel:
            print(f"Error: Could not find channel '{self.channel_name}'")
            return

        while self.is_running:
            try:
                # Use get_nowait() to check the queue without blocking the loop
                message = self.response_queue.get_nowait()
                # Use the channel object to send the message
                await channel.send(message)
                print(f"Twitch Response Sent: {message}")
            except Exception:
                # Queue is empty, just wait a moment before checking again
                await asyncio.sleep(0.5)

    async def event_message(self, payload):
        """Processes incoming chat messages from Twitch EventSub."""
        # NOTE: With AutoBot/EventSub, the incoming payload is usually a ChatMessage object.
        # It's good practice to check if it's a type we want to process.
        if not isinstance(payload, twitchio.ChatMessage):
            return

        # 1. Ignore messages from the bot itself (optional, but recommended)
        # We can check if the chatter ID matches the bot's ID
        # Access self.bot_id which should be set in __init__
        if payload.chatter.id == self.bot_id:
            return
        # 2. Extract Data
        message = payload.text
        author_name = payload.chatter.name
        author_id = payload.chatter.id
        # The 'tags' are now largely contained within the 'chatter' object.
        # We need to extract status information like 'mod', 'subscriber', 'vip' 
        # from the chatter's badges/status attributes.
        
        # For compatibility with TwitchChatItem, we create a pseudo-tags dictionary 
        # based on the chatter object's properties.
        tags = {
            'mod': payload.chatter.moderator, 
            'subscriber': payload.chatter.subscriber,
            'vip': payload.chatter.vip,
            # If you need specific badge data:
            # 'badges': payload.chatter.badges 
        }
        # 3. Map the Twitch message to our custom format
        # NOTE: We pass the full payload object as the first argument, as the 
        # custom TwitchChatItem's __init__ is expecting it to extract .content.
        
        # IMPORTANT: The TwitchChatItem class might need a slight adjustment 
        # if the 'message' object is expected to have a '.content' attribute.
        # Based on your dir(), we are passing the whole payload. Let's adjust TwitchChatItem
        # to accept the payload directly, or ensure we pass the 'text' correctly.
        
        # Assuming you've adjusted TwitchChatItem to accept the payload directly 
        # or are comfortable with the current structure:
        try:
            chat_item = TwitchChatItem(payload, author_name, author_id, tags)
        except Exception as e:
            # Fallback if TwitchChatItem is strictly looking for an old message structure
            # Let's adjust TwitchChatItem as a separate step to be safe.
            print(f"Error creating TwitchChatItem: {e}. Skipping message.")
            return

        # 4. Add the converted message to the queue for the synchronous loop
        self.reader_queue.append(chat_item)
        
        # 5. Allow twitchio's built-in command handler to run
        # NOTE: AutoBot handles commands automatically via listener decorators, 
        # but to ensure compatibility with your command structure, keep this line.
        # Since the AutoBot uses listeners, not commands, we technically don't need handle_commands,
        # but if you intend to add @commands.command() decorators later, leave it.
        # The EventSub message object is NOT a Context object, so 'handle_commands' may error 
        # if it expects a Context. It's often safer to rely only on Component/command decorators
        # with AutoBot. For now, let's keep it commented out until you add commands.
        # await self.handle_commands(payload)



    async def event_error(self, payload) -> None:
        print("Recv error")
        """Custom error handler for the bot. Now uses the payload argument."""

        # 1. Extract the actual exception from the payload if it exists
        if isinstance(payload, Exception):
            # This handles cases where the raw exception is passed (less common with AutoBot)
            error = payload
        elif hasattr(payload, 'exception'):
            # This handles the EventErrorPayload object, which wraps the exception
            error = payload.exception
        else:
            # Fallback for unexpected payload types
            error = Exception("An unknown error occurred during event processing.")

        print(f"Twitch Bot Error: {type(error).__name__}: {error}")
        self.is_running = False

        # 2. FIX: Cancel the background response task to clean up
        if self.response_task and not self.response_task.done():
            self.response_task.cancel()

        # 3. FIX: Stop the asyncio loop gracefully
        # Since we explicitly pass the loop in __init__, we can access it safely.
        # Check self.is_running before calling stop() to prevent race conditions during shutdown.
        if hasattr(self, 'loop') and self.loop.is_running():
            self.loop.stop()



class MyComponent(commands.Component):
    # An example of a Component with some simple commands and listeners
    # You can use Components within modules for a more organized codebase and hot-reloading.
    # TODO: Eventually convert existing command and validation to fit into this for !join !leave !save and leave room for more
    def __init__(self, bot: TwitchReaderBot) -> None:
        # Passing args is not required...
        # We pass bot here as an example...
        self.bot = bot

    # An example of listening to an event
    # We use a listener in our Component to display the messages received.
    @commands.Component.listener()
    async def event_message(self, payload: twitchio.ChatMessage) -> None:
        #print(f"[{payload.broadcaster.name}] - {payload.chatter.name}: {payload.text}")
        pass

    @commands.command()
    async def hi(self, ctx: commands.Context) -> None:
        """Command that replies to the invoker with Hi <name>!

        !hi
        """
        await ctx.reply(f"Hi {ctx.chatter}!")

    @commands.command()
    async def say(self, ctx: commands.Context, *, message: str) -> None:
        """Command which repeats what the invoker sends.

        !say <message>
        """
        await ctx.send(message)

    @commands.command(aliases=["thanks", "thank"])
    async def give(self, ctx: commands.Context, user: twitchio.User, amount: int, *, message: str | None = None) -> None:
        """A more advanced example of a command which has makes use of the powerful argument parsing, argument converters and
        aliases.

        The first argument will be attempted to be converted to a User.
        The second argument will be converted to an integer if possible.
        The third argument is optional and will consume the reast of the message.

        !give <@user|user_name> <number> [message]
        !thank <@user|user_name> <number> [message]
        !thanks <@user|user_name> <number> [message]
        """
        msg = f"with message: {message}" if message else ""
        await ctx.send(f"{ctx.chatter.mention} gave {amount} thanks to {user.mention} {msg}")

    @commands.group(invoke_fallback=True)
    async def socials(self, ctx: commands.Context) -> None:
        """Group command for our social links.

        !socials
        """
        await ctx.send("discord.gg/..., youtube.com/..., twitch.tv/...")

    @socials.command(name="discord")
    async def socials_discord(self, ctx: commands.Context) -> None:
        """Sub command of socials that sends only our discord invite.

        !socials discord
        """
        await ctx.send("discord.gg/...")

# 3. The PytChat-Mimicking Wrapper
class TwitchChatWrapper:
    """Wraps the asynchronous Twitch bot to look like a synchronous pytchat reader."""
    def __init__(self, channel_name: str,):
        self.message_queue = deque() # Incoming chat messages
        self.response_queue = Queue() # New: Outgoing responses for the bot
        self.loop = asyncio.new_event_loop()
        self.token_database = sqlite.connect("tokens.db")
        tokens, subs = setup_database(self.token_database)
        
        self.bot = TwitchReaderBot(channel_name, self.message_queue, self.response_queue,self.loop,token_db=self.token_database,tokens=tokens)

        self.thread = threading.Thread(target=self._run_bot_loop, daemon=True)
        self.thread.start()
        print("Twitch client started in background thread.")

    def _run_bot_loop(self):
        """Runs the asyncio loop in a separate thread."""
        asyncio.set_event_loop(self.loop)
        try:
            # When using run_until_complete with bot.start(), we don't need run_forever() 
            # as bot.start() is a long-running coroutine that blocks until the bot closes/errors.
            self.loop.run_until_complete(self.bot.start(load_tokens=True))
            
        except Exception as e:
            # If the bot fails to start (e.g., token not found/expired), this catches it.
            print(f"Twitch Bot failed to start/run: {e}")
        finally:
            self.loop.close()
            self.bot.is_running = False
            print("Twitch Bot Thread Shutting Down.")


    def is_alive(self) -> bool:
        """Checks if the bot's thread is still running."""
        # The bot itself also sets is_running=False on disconnect/error
        return self.bot.is_running and self.thread.is_alive()

    def get(self):
        """Mimic pytchat's get() method."""
        class SyncItems:
            def __init__(self, queue):
                self.queue = queue
            
            def sync_items(self):
                """Pulls all available messages from the queue and returns them."""
                items = []
                while self.queue:
                    # NOTE: .popleft() is thread-safe
                    items.append(self.queue.popleft())
                return items
                
        return SyncItems(self.message_queue)

    def raise_for_status(self):
        """Checks if the bot has unexpectedly died."""
        if not self.bot.is_running:
            raise ConnectionError("Twitch Bot connection was lost or failed to initialize.")

# --- END TWITCH INTEGRATION COMPONENTS ---


def get_chat_reader(platform: str, stream_id: str) -> Any:
    """Initializes and returns the appropriate chat reader based on platform."""
    if platform == 'youtube':
        try:
            return pytchat.create(video_id=stream_id)
        except Exception as e:
            # Pytchat failure can be non-critical if the user is forced to input later
            print(f"YouTube Chat failure for ID '{stream_id}': {e}")
            return None
    elif platform == 'twitch':
        if not stream_id:
            raise ValueError("Twitch stream ID (channel name) cannot be empty.")
        # stream_id here is the channel name (e.g., "mychannel")
        return TwitchChatWrapper(stream_id)
    else:
        raise ValueError(f"Unknown platform: {platform}")

if __name__ == '__main__':
    
    # 1. Determine stream ID and platform
    platform = SETTINGS['STREAM_PLATFORM'].lower()
    stream_id = SETTINGS.get(f'{platform}_stream_url')

    # Command-line override for stream ID
    if len(sys.argv) > 1:
        stream_id = sys.argv[1]
    
    # 2. Create the chat object
    print(f"Attempting to connect to {platform} chat with ID: {stream_id}")
    chat_reader = None
    response_queue = None # Initialize a variable for the response queue
    
    try:
        chat_reader = get_chat_reader(platform, stream_id)
        if platform == 'twitch' and chat_reader:
            response_queue = chat_reader.response_queue
    except NotImplementedError as e:
        print(f"ERROR: {e}")
        sys.exit(1)
        
    # 3. Handle YouTube ID failure/manual entry
    if platform == 'youtube' and not chat_reader:
        print("Video Id Failure, requiring manual entry...")
        ValidVideo = False
        userIn = ''
        while not ValidVideo:
            if len(userIn) > 0:
                    print(f"Video Id '{userIn}' is not valid")
            try:
                userIn = input("YouTube Video Id => ")
                chat_reader = get_chat_reader('youtube', userIn)
                if chat_reader:
                    SETTINGS['youtube_stream_url'] = userIn
                    ValidVideo = True
                else:
                    # Ensures the print message for invalid ID is displayed
                    pass 
            except:
                print("idk wtf this is for")
                pass
    elif not chat_reader:
            print(f"Could not initialize {platform} reader. Exiting.")
            sys.exit(1)

    # 4. Initialize directories and files
    if not os.path.exists(json_data):
        os.makedirs(json_data)

    if not os.path.exists(chatter_data):
        with open(chatter_data, 'w') as f:
            json.dump([], f) # Write empty list

    if not os.path.exists(sim_settings):
        with open(sim_settings, 'w') as f:
            json.dump({"entries_open": True}, f) # Write default settings here
    

    # 4.5. Initialize the ChatCommandProcessor
    # Pass SETTINGS and potentially set debug=False for production
    processor = ChatCommandProcessor(SETTINGS, test_mode=False, response_queue=response_queue)

    # 5. Main Loop
    print("Stream Reader initialized")
    errorTimeout = 0
    while errorTimeout <= 3: 
        # Pass the processor instance to readChat
        result = readChat(chat_reader, processor) 
        
        if result == False:
            print("readChat got error, attempting re-init...")
            errorTimeout += 1 
            
            # Re-initialize only if using YouTube (for simplicity)
            if platform == 'youtube':
                chat_reader = get_chat_reader('youtube', SETTINGS['youtube_stream_url'])
        else:
            errorTimeout = 0 
            
        time.sleep(0.2) 
    print("ReadChat Timeout Error")

'''
import asyncio
import twitchio

Grabs user ids
CLIENT_ID: str = my_secrets['client_id']
CLIENT_SECRET: str = my_secrets['client_secret']

async def main() -> None:
    async with twitchio.Client(client_id=CLIENT_ID, client_secret=CLIENT_SECRET) as client:
        await client.login()
        user = await client.fetch_users(logins=["ccscrapracingbot", "ccscrapracingleague"])
        for u in user:
            print(f"User: {u.name} - ID: {u.id}")

if __name__ == "__main__":
    asyncio.run(main())

'''
import MusicPlayer
from MusicPlayer import play_dynamic_music, check_music_finished_and_loop
import os, json, random, math, time
import requests
import sharedData
import datetime
from sharedData import addToQueue
import helpers
from obswebsocket import obsws, requests as obs_requests
# Add this:
# import logging
# logging.basicConfig(level=logging.INFO) # optional: better logging for debugging

#Twitch Chat Scopes: 'channel:bot channel:manage:ads channel:read:ads channel:edit:commercial channel:read:polls channel:manage:polls channel:read:predictions channel:manage:predictions channel:read:redemptions channel:manage:redemptions user:bot user:write:chat'

dir_path = os.path.dirname(os.path.realpath(__file__))
main_path = dir_path
realtime_path = os.path.join(main_path,"JsonData/RaceOutput/raceData.json")
twitch_path =  os.path.join(main_path, "TwitchPlays")
Twitch_json = os.path.join(twitch_path, "BotData")
sim_settings = os.path.join(Twitch_json, 'settings.json')
STATS_FILENAME =  os.path.join(Twitch_json,"user_race_stats.json")
FIELD_RACER_TITLE = "The Field (Other Racers)"
ALL_NAMES = [] # List of Bot names that Race manager can choose from when spawning bots
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
BOT_NAMES = [
    "DataStream_BOT", "CodeZero_BOT", "ByteShift_BOT", "AlgoRhythm_BOT",
    "NitroGen_BOT", "RaceGhost_BOT", "ApexDrift_BOT", "TurboKat_BOT",
    "CypherKing_BOT", "DeltaWing_BOT", "EchoPrime_BOT", "NexusRex_BOT",
    "QueryBot_BOT", "StatMaster_BOT", "LogicFlow_BOT", "PilotOne_BOT",
    "GlitchRider_BOT", "IronMuse_BOT", "VectorX_BOT", "ZenithAI_BOT"
]
RACE_START_DELAY = 400 #400
RACE_FINISH_DELAY = 300 # 300
AUTO_START_DELAY = 30 # how long to wait until auto start
INTRO_SCREEN_LENGTH = 200
FINISH_SCREEN_LENGTH = 100

RACE_CAPACITY = 16 # TOtal number of racers allowed
class RaceManager():
    MAX_LAP_TIME_SENTINEL = 9999999999
    def __init__(self,config_manager,socketio_server):
        self.TwitchRaceEnabled = True # Whether we are doing twitch or smarl race
        self.config_manager = config_manager
        # Load attributes from config (now using .get() method)
        self.TWITCH_CLIENT_ID = self.config_manager.get("TWITCH_CLIENT_ID")
        self.TWITCH_CLIENT_SECRET = self.config_manager.get("TWITCH_CLIENT_SECRET")
        self.TWITCH_BROADCASTER_ID = self.config_manager.get("TWITCH_BROADCASTER_ID")
        # Load the critical tokens
        self.TWITCH_ACCESS_TOKEN = self.config_manager.get("TWITCH_ACCESS_TOKEN")
        self.TWITCH_REFRESH_TOKEN = self.config_manager.get("TWITCH_REFRESH_TOKEN")

        # Prediction State Variables
        self.predictions_enabled = False # on by default (Disabled until channel points eligible)
        self.prediction_active = False
        self.prediction_id = None
        self.racer_names = []
        self.outcome_map = {}
        self.enabled = True
        self.timer = 0
        self.lastSeconds = -10
        self.updateTicks = 10 # How Fast race outputs new data (based on RaceConrol outputTimer delay
        self.hzConvert = 40/self.updateTicks # Update Frequency we get onUpdate() from new data (based off of onfixed 40hz)
        self.freshStart = True
        self.raceFinishCountdown = 0 # Counter After finish before reset
        self.raceStartCountdown = RACE_START_DELAY # Counter until auto start is called
        self.raceFinishDelay = RACE_FINISH_DELAY
        self.finishTimerRunning = False # Unused properly
        self.autoStartCountDown = AUTO_START_DELAY
        self.autoStartTimerRunning = False
        self.stream_timer_output = " " # Text for OBS to display of current race information
        self.totalCars = 0
        self.raceMode = 0
        self.raceStatus = 0
        self.lapsLeft = None
        self.autoStarted = False # So that we dont accidentally re trigger auto starts
        self.entriesOpen = True
        self.raceFinished = False
        self.deletingRacers = False # True when waiting for delete confirmation
        self.stoppingRace = False # confiurmation flag for race stop
        self.startingRace = False # confirmation flag for race start
        self.usersEntered = []
        self.settingsFilename = sim_settings
        self.statsFilename = STATS_FILENAME
        self.commandQueue = [] # List of commands to execute on each update
        self.commandFailures = {}
        self.commandRestarts = {}
        self.MAX_QUEUE_FAILURES = 5 # Constant for max retries
        self.MAX_RESTART_RETRIES = 3 # number of restart command retries
        self.pendingSpawns = {} # list of user_ids that have a spawn command queued/recently issued and their timestamps
        self.confirmedSpawns = {} # list of confirmed known spawns, 
        self.respawn_cooldown = 5 # Seconds to wait for the game to respond
        self.grace_period = 5 # Forgive a car for missing up to 5 seconds
        
        
        # api Function calls (will get updated and populated by application.py)
        self.api_remove_racer = None
        self.api_set_race = None
        self.api_reset_race = None
        self.api_delete_all_racers = None

        # Ticker data structure
        self.best_lap_time = "N/A"
        self.best_lap_racer = "N/A"
        self.last_winner = "N/A"
        self.next_race_time = "TBA" # Can be updated with real time if needed (Not using for now)
        self.total_season_racers = 0 # Number of cars entered this season
        # Auto fill bot 
        self.autoFill = True # whether to do it or not
        self.autoFilling = False # Actively autoFilling
        #Obs websocket control
        self.obs_enabled = True # Whether to do automated obs actions
        self.obs_url = "localhost"
        self.obs_port = 4455
        self.obs_pass = self.config_manager.get('obs_ws')
        self.obs_client = self.connect_to_obs()
        self.obs_all_scenes = ["MAIN","Race Overlay Texts" "Intro Display", "Race Splits", "Race Finish", "Season Standings"]
        self.obs_cur_scene = "Race Overlay Texts" # Raw just game scene (use index??)
        self.obs_switch_scene(self.obs_cur_scene)
        self.obs_intro_timer = -1 # How long to hold the Intro Display after race start
        self.obs_intro_timerRunning = False # if the timer is running
        self.obs_finish_timer = -1 # How long to hold the finish Display after race start
        self.obs_finish_timerRunning = False # IF the finish timer running


        # Chat Controls Specific
        # Spotlighted racer
        self.spotlight_racer_uid = None
        self.spotlight_timer = 0.0 # Time remaining for the spotlight display
        self.spotlight_duration = 15.0 # Display for 15 seconds

        # SMARL SPecific
        self.SMARL_ENABLED = False # TDODO: alter this so we differnciate betwen smarl and CCSRL functions
        self.results_uploaded = {'race': False, 'quali': False}
        self.current_raw_data = None # Store the latest full packet
        self.tag_lookup = {} # Stores {'stable_id': 'TAG'} generated from current race
        self.sio = socketio_server # The Flask-SocketIO server instance
        # Initialize internal structures
        # self.racer_data = self._load_initial_racer_data() # Logic from getAllRacerData

        #Init functions
        self._load_track_record()
        self.overlay_data = self.build_overlay_data()
        self.openEntries() # Auto opens entries on Start (Small Delay?)



    def build_overlay_data(self):
        live_data = {
            "status": self.raceStatus,
            "race_timer_information": self.stream_timer_output, # Dynamic output Since we are no longer just pulling from the text file 
            "racer_count": f'{self.totalCars}/{RACE_CAPACITY}',
            "entries_status": self._get_entries_status_text(),
            # 2. Add Music Information
            "current_song": {
                "title": MusicPlayer.CURRENT_PLAYING_TITLE,
                "artist": MusicPlayer.CURRENT_PLAYING_ARTIST
            },
            
            # 3. Add Statistics Ticker Data (see next section)
            "stats_ticker": self.get_ticker_data() 
        }
        return live_data

    # LOG PARSER REPLACEMENT:
    def process_and_broadcast_data(self, raw_data):
        """
        Takes raw data from the file poller, parses it, updates state, 
        uploads results if finished, and broadcasts to the web clients.
        """
        if not raw_data:
            return

        parsed_data = self.parse_data(raw_data)
        # 2. Broadcasting (replaces LogParser.py's outputData)
        self.sio.emit('raceData', parsed_data)
        # Note: self.sio is the server instance from Application.py, making this direct.
        
        # 3. State Update & Result Check (replaces LogParser.py's process_game_update logic)
        self._update_state_and_check_results(parsed_data)

    # -----------------------------------------------------------------
    # STATE AND UPLOAD LOGIC: Replaces global checks
    # -----------------------------------------------------------------
    def _update_state_and_check_results(self, parsed_data):
        """Replaces the entire logic block from the old process_game_update."""
        self.onUpdate(parsed_data)
        # Update car count (replaces global TOTALCARS)
        self.total_cars = len(parsed_data.get('realtime_data', []))

        meta = parsed_data.get('meta_data', {})
        if meta.get('lapsLeft') == -1 and self.total_cars > 0:
            
            num_finishers = len(parsed_data.get('finish_data', []))
            num_qualifiers = len(parsed_data.get('qualifying_data', []))

            # Race Finish Check (replaces UPLOADED_RACE global) TODO: just use the self.raceFinished variable that triggers when all racers are finished
            if not meta.get('qualifying') and num_finishers == self.total_cars and not self.results_uploaded['race']:
                print("Finished Race. Uploading results...",self.raceFinished)
                if self.upload_race_results(parsed_data['finish_data']): # Calls the method below
                    self.results_uploaded['race'] = True
                    # Resolve prediction logic here (potentially?)
            
            # Qualifying Finish Check (replaces UPLOADED_QUALI global)
            elif meta.get('qualifying') and num_qualifiers == self.total_cars and not self.results_uploaded['quali']:
                print("Finished Qualifying. Uploading results...",self.raceFinished)
                if self.upload_qual_results(parsed_data['qualifying_data']): # Calls the method below
                    self.results_uploaded['quali'] = True

    # -----------------------------------------------------------------
    # DATA PARSING:
    # -----------------------------------------------------------------
    def parse_data(self,raw_data):
        def _get_safe_list(key):
            """Safely extracts a list from raw_data, handles missing keys and 'null' values."""
            raw_value = raw_data.get(key)
            # Return the value if it's a list; otherwise, return an empty list
            return raw_value if isinstance(raw_value, list) else []
        # ----------------------------------------------------
        # NEW STEP: PASS 1 - COLLECT NAMES AND GENERATE UNIQUE TAGS
        # ----------------------------------------------------
        all_raw_racers = []
        
        # 1. Collect all unique racer data from the raw input
        # Use a set to track IDs we've already seen to prevent double-counting
        seen_ids = set() 
        # Check Realtime data (most complete list of active racers)
        for data in _get_safe_list('rt'):
            if data.get('id') not in seen_ids:
                all_raw_racers.append(data)
                seen_ids.add(data.get('id'))
                
        # Check Qualifying and Finish data for racers missing from Realtime (less common, but safe)
        for key in ['qd', 'fd']:
            for data in _get_safe_list(key): # Now raw_list is guaranteed to be an iterable (either a list or [])
                # Use 'racer_id' for these lists
                racer_id_key = data.get('racer_id')
                if racer_id_key and racer_id_key not in seen_ids:
                    all_raw_racers.append(data)
                    seen_ids.add(racer_id_key)

        # 2. Generate all unique tags and store in a lookup dict
        self.tag_lookup = {}
        self.existing_tags = set()
        
        for raw_racer_data in all_raw_racers:
            # Determine the name to use for tagging (Twitch name preferred if available)
            name_to_tag = raw_racer_data.get('name', raw_racer_data.get('display_name', 'Unknown'))
            
            # Determine the stable ID for the lookup key
            stable_id = raw_racer_data.get('uid', raw_racer_data.get('id', raw_racer_data.get('racer_id')))

            if stable_id is None:
                continue
            # NOTE: Your raw data IDs are floats (25.0, 31.0). They MUST be strings here.
            final_lookup_key = str(int(stable_id)) if isinstance(stable_id, float) else str(stable_id)
            new_tag = self.generate_unique_tag(name_to_tag, self.existing_tags)
            self.tag_lookup[final_lookup_key] = new_tag
            self.existing_tags.add(new_tag)
            
        # Now tag_lookup has all unique tags: {stable_id: 'TAG', ...}
        # ----------------------------------------------------
        # END PASS 1
        # ----------------------------------------------------
        outputData = {
            'meta_data': {},
            'qualifying_data': [],
            'finish_data': [],
            'realtime_data': []
        }

        # ================== METADATA ==================
        metaData = raw_data.get('md', {})
        status_code = int(metaData.get('status', 0))
        status_map = {
            1: "Green Flag", 3: "Formation", 2: "Caution", 0: "Stopped", -1: "Qualifying"
        }
        outputData['meta_data'] = {
            'id': 1, 
            'status': status_map.get(status_code, "Unknown"),
            'lapsLeft': metaData.get('lapsLeft', 0),
            'qualifying': metaData.get('qualifying') == "true" # Boolean conversion
        }

        # ================== REALTIME DATA ==================
        raceData = []
        for data in _get_safe_list('rt'):
            racerID = data.get('id')
            if racerID is None:
                continue
                
            racer_details = self._get_racer_details(racerID, data)
            if racer_details.get('tag') is None:
                continue

            # Map raw data to final keys
            racer_data = {
                # Identity (from helper)
                **racer_details, 
                # Race Data (direct mapping and conversion)
                'pos': int(data.get('place', 0)),
                
                # [UPDATED] Key names matched to Lua
                'lapNum': int(data.get('lap', 0)),     # Was 'lapNum', now 'lap'
                'lastLap': helpers.get_time_from_seconds(float(data.get('lastLap', 0.0))),
                'bestLap': helpers.get_time_from_seconds(float(data.get('bestLap', 0.0))),
                
                # [UPDATED] Gaps are now explicitly named
                'gapToLeader': data.get('gapTime', "0.000"), # Was 'gapToLeader', now 'gapTime'
                'gapToNext': data.get('interval', "0.000"),  # Was 'gapToNext', now 'interval'
                
                'locX': data.get('locX', 0.0),
                'locY': data.get('locY', 0.0),
                'speed': data.get('speed', 0.0),
                
                # [NEW] Map Visualization Helpers
                'prog': data.get('prog', 0.0), 
                'dist': data.get('dist', 0.0),

                'isFocused': data.get('isFocused', 'false') == 'true', 
                
                # Enhanced Data (direct mapping)
                'st': data.get('st', ""),
                'fl': data.get('fl', 0.0),
                'th': data.get('th', 0.0),
                'ps': data.get('pitState', 'N/A'),
                'finished': data.get('finished', False)
            }
            raceData.append(racer_data)
        outputData['realtime_data'] = raceData
        
        # ================== QUALIFYING/FINISH DATA (Consolidated Logic) ==================

        def _parse_race_list(data_key, id_key='racer_id', pos_key='position'):
            parsed_list = []
            for data in _get_safe_list(data_key):
                racerID = data.get(id_key)
                if racerID is None: continue
                    
                racer_details = self._get_racer_details(racerID, data)
                if racer_details.get('tag') is None: continue

                entry = {
                    **racer_details,
                    'pos': int(data.get(pos_key, 0)),
                    'bestLap': helpers.get_time_from_seconds(float(data.get('best_lap', 0.0))),
                    'split': str(data.get('split', "0.000")), #TODO: rename this to gapToLeader and propogate
                    'finishTime': str(data.get('finishTime', "0.000")),
                }
                # For finish data, include the original 'userid' as 'uid' if available
                if data_key == 'fd':
                    entry['uid'] = data.get('racer_id', 'unknown') # Using racer_id here as per your original code
                
                parsed_list.append(entry)
            return parsed_list

        outputData['qualifying_data'] = _parse_race_list('qd')
        outputData['finish_data'] = _parse_race_list('fd')

        return outputData

    # -----------------------------------------------------------------
    # UPLOAD METHODS: Replaces LogParser.py's upload* functions
    # -----------------------------------------------------------------

    def upload_qual_results(self,finishData): # same as finish but just qualifying
        if self.TwitchRaceEnabled: # Skip upload
            return True
        race_id = sharedData._SpecificRaceData['race_id']
        track_id = sharedData._SpecificRaceData['track_id']
        timestamp = datetime.datetime.now().strftime("%m/%d/%Y %H:%M:%S") # What to do with this?
        fastestLap,fastestRacer = helpers.getFastestLap_racer(finishData)
        fastRacerName = fastestRacer['name']
        #print("Fastest lap and racer:",fastestLap,fastRacerName)
        status = sharedData.track_record_managment(track_id,fastestLap,fastestRacer)
        results = self.generateResultString(finishData)
        print("Got qualifying results,",results,"New Lap Record?",status)
        print("Uploading Qualifying results: ")
        result = sharedData.uploadQualResults(race_id,results)
        return result #TODO: Uncomment these when ready


    def upload_race_results(self,finishData):
        if self.TwitchRaceEnabled: # Skip upload
            return True
        race_id = sharedData._SpecificRaceData['race_id']
        track_id = sharedData._SpecificRaceData['track_id']
        timestamp = datetime.datetime.now().strftime("%m/%d/%Y %H:%M:%S") # What to do with this?
        fastestLap,fastestRacer = helpers.getFastestLap_racer(finishData)
        fastRacerName = fastestRacer['name']
        status = sharedData.track_record_managment(track_id,fastestLap,fastestRacer)
        results = self.generateResultString(finishData)
        print("Got Race results,",results,"New Lap Record?",status)
        print("Uploading race results: ")
        result = sharedData.uploadResults(race_id,results)
        return result


    # =================================================================
    # PRIVATE HELPER METHODS (Moved from LogParser.py or created for structure)
    # =================================================================
    
    def _collect_all_raw_racers(self, raw_data):
        """Collects unique racer data for tag generation."""
        all_raw_racers = []
        seen_ids = set() 
        for data in raw_data.get('rt', []):
            if data.get('id') not in seen_ids:
                all_raw_racers.append(data)
                seen_ids.add(data.get('id'))
        
        for key in ['qd', 'fd']:
            for data in raw_data.get(key, []):
                racer_id_key = data.get('racer_id') 
                if racer_id_key and racer_id_key not in seen_ids:
                    all_raw_racers.append(data)
                    seen_ids.add(racer_id_key)
        return all_raw_racers
        
    def _generate_all_tags(self, all_raw_racers):
        """Generates unique tags for all racers in the current data packet."""
        tag_lookup = {}
        existing_tags = set()
        
        for raw_racer_data in all_raw_racers:
            name_to_tag = raw_racer_data.get('name', raw_racer_data.get('display_name', 'Unknown'))
            stable_id = raw_racer_data.get('uid', raw_racer_data.get('id', raw_racer_data.get('racer_id')))

            if stable_id is None:
                continue
                
            # These two methods would also be moved into the class as private methods
            new_tag = self._generate_unique_tag(name_to_tag, existing_tags)
            
            tag_lookup[stable_id] = new_tag
            existing_tags.add(new_tag)
            
        return tag_lookup

    # Helper method to create a unique short tag (e.g., 'Joe' -> 'JOE')
    def generate_unique_tag(self, name, existing_tags):
        """
        Creates a short, unique 4-letter tag based on the provided name.
        """
        if not name or not isinstance(name, str):
            return None
        cleaned_name = name.replace(' ', '')
        # If the name was only spaces or became empty after cleaning, handle it.
        if not cleaned_name:
            # Fallback logic if needed, but 'Unknown' should cover this if used 
            return self.generate_unique_tag("UNK", existing_tags)

        # 1. Base Tag: Use the first three letters, upper-cased
        base_tag = cleaned_name[:4].upper()

        # 2. Check for uniqueness (Handles conflicts by appending a number)
        if base_tag not in existing_tags:
            return base_tag
        
        # 3. Handle conflict: Append a number
        i = 1
        while True:
            unique_tag = f"{base_tag}{i}"
            if unique_tag not in existing_tags:
                return unique_tag
            i += 1
    
    def _get_racer_details(self, racerID, raw_driver_data):
        """Logic from LogParser._get_racer_details, uses self.tag_lookup."""
        try:
             formatID = str(int(racerID))
        except (ValueError, TypeError):
             formatID = str(racerID)
        
        league_data = helpers.find_racer_by_id(formatID, sharedData._RacerData)
        if league_data == None and self.TwitchRaceEnabled == False and self.SMARL_ENABLED == True:
            # The external server is not Running to pass _RacerData
            print("Critical Error Cannot grab league data")
            #Skip this racer, it should not even be in the race
            return 

        if league_data:
            # League Racer logic... using self.tag_lookup for the 'tag' key
            # IMPORTANT: If league_data is present, the stable_id for the tag lookup
            # MUST be the same key used in Pass 1 for this racer.
            # It should be the formatted game ID (formatID), not display_name.
            # If your tag generation uses 'display_name' as the key:
            stable_id_key = formatID  #league_data.get('display_name', 'UnknownOwner')
            # If your tag generation uses the game ID (recommended):
            # stable_id_key = formatID 
            tag = self.tag_lookup.get(stable_id_key)
            colors = league_data.get('colors', '#FFFFFF,#FFFFFF,#222222').split(",")
            return {
                'id': racerID, 
                'owner': stable_id, 
                'name': league_data.get('name', 'No Name'),
                'tag': self.tag_lookup.get(stable_id, 'XXXX'), # KEY CHANGE: uses self.tag_lookup
                'primary_color': colors[0],
                'secondary_color': colors[1],
                'tertiary_color': colors[2],
            }
        else:
            # Twitch Racer logic... using self.tag_lookup for the 'tag' key
            colors = raw_driver_data.get('colors', '#FFFFFF,#FFFFFF,#222222').split(",")
            stable_id = raw_driver_data.get('uid', raw_driver_data.get('userid', 'NoUserID'))
            tag = self.tag_lookup.get(stable_id)
            return {
                'id': racerID, 
                'owner': stable_id, 
                'name': raw_driver_data.get('name', 'No Name'),
                'tag': self.tag_lookup.get(stable_id, 'XXXX'), # KEY CHANGE: uses self.tag_lookup
                'uid': formatID,
                'racer_id': formatID,
                'primary_color': colors[0],
                'secondary_color': colors[1],
                'tertiary_color': colors[2],
            }

    def _parse_realtime_data(self, raw_rt_list):
        """Helper to parse the 'rt' list."""
        raceData = []
        for data in raw_rt_list:
            racerID = data.get('id')
            if racerID is None: continue
                
            racer_details = self._get_racer_details(racerID, data)
            if racer_details.get('tag') is None: continue

            racer_data = {
                 # Identity (from helper)
                **racer_details, 
                # Race Data (direct mapping and conversion - uses helper.get_time_from_seconds)
                'pos': int(data.get('place', 0)),
                'lapNum': int(data.get('lapNum', 0)),
                'lastLap': helpers.get_time_from_seconds(float(data.get('lastLap', 0.0))),
                'bestLap': helpers.get_time_from_seconds(float(data.get('bestLap', 0.0)))
            }
            raceData.append(racer_data)
        return raceData

    def _parse_race_list(self, raw_list, id_key, pos_key):
        """Helper to parse 'qd' or 'fd' lists."""
        parsed_list = []
        for data in raw_list:
            racerID = data.get(id_key)
            if racerID is None: continue
                
            racer_details = self._get_racer_details(racerID, data)
            if racer_details.get('tag') is None: continue

            entry = {
                **racer_details,
                'pos': int(data.get(pos_key, 0)),
                'bestLap': helpers.get_time_from_seconds(float(data.get('bestLap', 0.0))),
                'timeSplit': data.get('timeSplit', "0.000"),
                'split': str(data.get('split', "0.000")),
            }
            parsed_list.append(entry)
        return parsed_list
        
    def _generate_result_string(self, data):
        """Logic from LogParser.generateResultString."""
        output = ""
        sortedData = helpers.sortByKey('pos',data)
        for result in sortedData:
            output += str(result['id']) + ","
        return output.strip(",")

    # stats helpers and generators
    def get_ticker_data(self):
        """Compiles current race statistics into a list of strings."""
        
        #print("Getting stats ticker",self.best_lap_time,self.total_season_racers)
        ticker_list = [
            f"Use '!join' to join an open race. Details in description below",
            f"Current Track Record: {self.best_lap_time} by {self.best_lap_racer}",
            f"Last Race Winner: {self.last_winner}",
            f"Next Race Approximate Start: {self.next_race_time}", # Tis is unecessary and will be unused for now but I like the idea
            f"Total Entrants This Season: {str(self.total_season_racers)}" # Uses total cars with saved stats
        ]
        
        # We already have overlay displaying current racers and count/capacity
             
        return ticker_list
    
    def _get_seconds_from_ticks(self,ticks): # Returns approximate seconds for each onUpdate tick (based off of hz)
        return round(ticks/self.hzConvert)

    def _approximate_next_race(self, data): 
        """
        Approximates the time of the next race by iterating over realtime car data,
        Averages the last lap time of all racers (after converting the string to seconds)
        Adds the ammount of seconds it takes to reset the race (Race finish delay)
        Adds a small padding of 5 seconds
        Takes the current time and adds the newly calculated seconds to it
        Outputs the new time as a formatted string: "HH:MM:SS EST" (full time zone formatted time)
        """
        # takes average of last lap times
        avgLapTime = 1
        padding = -20
        finishDelay = self._get_seconds_from_ticks(RACE_FINISH_DELAY)
        totalTime = 0
        nexRaceStr = "N/A"
        timeList = []
        cutCount = 2
        try:
            for car in data:
                # IMPORTANT: Accessing car['lastLap'] not data['lastLap']
                lastLapstr = car['lastLap']
                timeList.append(helpers.get_seconds_from_time(lastLapstr))
            # Check if there are enough times to cut
            if len(timeList) <= cutCount:
                # Handle case where cutting is impossible/meaningless
                print("Not enough lap times to exclude the specified number of slowest times.")
                # Optionally, you can just calculate the average of the whole list here
                # avgLapTime = sum(timeList) / len(timeList) if timeList else 0 
            else:
                timeList.sort()
                sliced_time_list = timeList[:len(timeList) - cutCount]
                sum_of_times = sum(sliced_time_list)
                count_of_times = len(sliced_time_list)
                avgLapTime = sum_of_times / count_of_times


        except Exception:
            # Handle cases where 'lastLap' or helpers.get_seconds_from_time fails
            return "N/A"
            
        totalTime = avgLapTime + finishDelay + padding # Delay until next race (in seconds)
        
        now_utc = datetime.datetime.now(datetime.timezone.utc)
        time_delta = datetime.timedelta(seconds=totalTime)
        nextRaceTime_utc = now_utc + time_delta
        # %Z gives the timezone abbreviation (UTC)
        nexRaceStr = nextRaceTime_utc.strftime("%H:%M:%S %Z")

        return nexRaceStr

        

    def grabUserStats(self): # reads and returns user stats from json file (or db?)
        """
        Reads and returns user stats from the JSON file. 
        Returns an empty dict if the file is missing or contains errors.
        """
        try:
            # Define the file path (adjust if STATS_FILENAME is defined elsewhere)
            file_path = self.statsFilename
            
            with open(file_path, 'r') as infile:
                user_stats = json.load(infile)
                #print(f"Successfully loaded {len(user_stats)} user stats.")
                return user_stats
                
        except FileNotFoundError:
            # Common on first run or if file was deleted
            #print(f"Stats file '{self.statsFilename}' not found. Initializing empty stats.")
            return {}
            
        except json.JSONDecodeError:
            # File exists but is corrupted (e.g., partial write)
            print(f"ERROR: Stats file '{self.statsFilename}' is corrupted. Returning empty stats.")
            # Consider making a backup of the corrupted file before returning {}
            return {}

    def saveUserStats(self, data):
        """
        Saves the entire user stats dictionary to the JSON file.
        The 'data' dict should be indexed by 'userid' (string).
        """
        try:
            # Define the file path (adjust if STATS_FILENAME is defined elsewhere)
            file_path = self.statsFilename

            with open(file_path, 'w') as outfile:
                # Use 'indent=4' for readable file formatting (helpful for debugging)
                json.dump(data, outfile, indent=4)
                print(f"Successfully saved {len(data)} user stats to file.")
                
        except Exception as e:
            # Catch generic I/O errors (permissions, disk space, etc.)
            print(f"ERROR: Could not save stats to '{self.statsFilename}': {e}")
    

    def _load_track_record(self):
        """
        Scans all saved user stats to find and set the overall best lap time 
        and the corresponding racer for the overlay. Called on initialization.
        """
        current_stats = self.grabUserStats()
        self.total_season_racers = len(current_stats)
        # Initialize with the highest possible time
        global_best_time_sec = self.MAX_LAP_TIME_SENTINEL 
        global_best_racer_name = None
        for user_id, stats in current_stats.items():
            user_best_lap_str = stats.get('best_lap_time', helpers.get_time_from_seconds(self.MAX_LAP_TIME_SENTINEL)) #redundant...
            # 2. Convert the stored string time into a comparable numeric seconds value
            try:
                # Use your helper to get the float (seconds) from the formatted string
                user_best_lap_sec = helpers.get_seconds_from_time(user_best_lap_str)
            except Exception:
                # Failsafe for "N/A", None, or unparseable initial/legacy values
                user_best_lap_sec = self.MAX_LAP_TIME_SENTINEL

            # Use 'name' from the stats if available, or fall back to the ID
            racer_name = stats.get('name', str(user_id)) 
            if user_best_lap_sec < global_best_time_sec:
                global_best_time_sec = user_best_lap_sec
                global_best_racer_name = racer_name
                
        # Update instance variables
        if global_best_time_sec < self.MAX_LAP_TIME_SENTINEL:
            # Format the time (assuming time is a float/integer representing seconds/ms)
            self.best_lap_time = helpers.get_time_from_seconds(global_best_time_sec)
            self.best_lap_racer = global_best_racer_name
        else:
            self.best_lap_time = "N/A"
            self.best_lap_racer = "N/A"
            
        # Also load the last winner if you have a reliable way to store it (not currently defined)
        # For simplicity, we'll keep last_winner as N/A until the first race finishes.
        print(f"Loaded Track Record: {self.best_lap_time} by {self.best_lap_racer}")

    def respawn_twitch_racer(self,racer): # Directly tells game to spawn racer (does not add to usersEntered, used to rectify failed add)
        racerData = {
            'userid': racer['userid'],
            'username':racer['username'],
            'bp': racer['bp'],
            'colors':racer['colors']
        }
        self.totalCars = len(self.usersEntered)
        self.queue_racer_spawn(racerData) 


    def queue_racer_spawn(self, racer_data):
        """Adds a racer's spawn command to the sharedData queue."""
        apiCommand ={
            'cmd': 'genCAR',
            'val': [racer_data['userid'], racer_data['username'], racer_data['bp'], racer_data['colors']]
        }
        # This is the line that triggers the game to spawn the car.
        #TODO: Possibly quueue this up if we know we havae a large list coming (only autoFill?)
        results = addToQueue([apiCommand])
        return results

    def onJoin(self,command): # executes on join API request of racer, is the middleman between the stream parser and the game
        
        print("handling join",self.totalCars,len(self.usersEntered),command['username'])
        # Exta bot che king here? and command.get('is_bot',False) == False
        if self.entriesOpen == False: # if entries are closed and not a bot is joining
            return False # TODO: check if bot
        
        if self.obs_cur_scene != "Intro Display": # Switch to entries when people start to join
            self.obs_switch_scene("Intro Display")

        user_id = command.get('userid')
        if any(d.get('userid') == user_id for d in self.usersEntered):
            print(f"Join rejected, User ID {user_id} is already in Race.")
            return False
        

        # CHECK FOR SAVED CAR IF JOIN COMMAND IS MISSING DATA
        if user_id and (command.get('bp')) == "saved" :
            user_stats = self.grabUserStats()
            self.total_season_racers = len(user_stats)
            stats = user_stats.get(user_id)
            if stats and stats.get('saved_bp') and stats.get('saved_colors'):
                # Overwrite the command with saved car data
                command['bp'] = stats['saved_bp']
                command['colors'] = stats['saved_colors']
                print(f"Loading saved car for {command['username']}.")
            else:
                command['bp'] = random.choice(ALL_BPS)
        
        racerData = {
            'userid': command['userid'],
            'username':command['username'],
            'bp': command['bp'],
            'colors':command['colors'],
            'is_bot': command['is_bot']
        }
        # 1. ADD TO ACCEPTED LIST
        self.usersEntered.append(racerData)
        self.totalCars = len(self.usersEntered)
        # 2. QUEUE SPAWN COMMAND & TRACK AS PENDING
        self.queue_racer_spawn(racerData) 
        self.pendingSpawns[user_id] = time.time()
        self.racer_names.append(racerData['username'])
        if self.totalCars >= RACE_CAPACITY:
            self.closeEntries()
            return True

        return True
        
    def openEntries(self): # Opens entries 
        self.entriesOpen = True
        self.raceStartCountdown = RACE_START_DELAY
        self.autoStarted = False
        self.autoFilling = False

        print("--- Opening RACE ENTRIES ---")
        result = self.updateSettings('entries_open',True)
        if self.obs_cur_scene not in ["Intro Display", "Season Standings"]: #Only switch when not here
            self.obs_cur_scene = "Intro Display" # Raw just game scene (use index??)
            self.obs_switch_scene(self.obs_cur_scene)
        return result

    def closeEntries(self):
        """
        Finalizes the entry period, closes all relevant flags, and updates 
        external systems (settings/music).
        """
        print("--- CLOSING RACE ENTRIES ---")
        
        # 1. State Flag Resets
        self.entriesOpen = False
        
        # Manually trigger a stop/reset on the main countdown timer, 
        # ensuring it doesn't try to run in the next phase of the tick loop.
        self.raceStartCountdown = 0 
        
        # 2. External System Sync
        # Update the external settings file/API endpoint
        result = self.updateSettings('entries_open', False)
        
        # 3. Music/Visual Sync (Crucial for a clean transition)
        # The music should switch from 'PREP' to a more intense 'START' or be stopped/muted.
        # Assuming you have a function to handle music control:
        #play_dynamic_music("START") 
        
        return result
           

    def startRace(self): # starts racec
        result = self.api_set_race(3) # Starts formation lap
        return result

    def stopRace(self): # Stops race
        result = self.api_set_race(0)
        return result
    
    def resetRaceControl(self): # Have a confirm one too??
        result = self.api_reset_race()
        return result
    
    def confirmRaceStop(self): 
        #self.autoStarted = False
        """
        Sends the stop command (0) and waits for the game status to confirm "Stopped".
        """
        # --- State 1: Initiation (Only runs once) ---
        if self.stoppingRace == False:
            self.stoppingRace = True
            
            # 1. Initiate the API call to stop the race
            api_result = self.api_set_race(0) # 0 = stop
            print(f"Initiated Race Stop via API. Result: {api_result}. Starting confirmation process.")
            
            if api_result is False or api_result is None:
                # The API call itself failed (connection/timeout). 
                # executeQueue will catch this failure and retry the command.
                self.stoppingRace = False # Reset flag for next retry
                return api_result 

            # API call succeeded. Now fall through to the monitoring state for the next tick.
            # Returning False here is technically correct as we are now WAITING, 
            # but to keep the flow clean, we let the next section handle the check.

        # --- State 2: Monitoring (Runs until raceStatus is "Stopped") ---
        # This executes on the next tick after the API call, and continues every tick thereafter.
        if self.raceStatus == "Stopped":
            print("Race Stop confirmed by game status.")
            self.stoppingRace = False # Crucial: Reset the flag upon success
            return True # Success!
        else:
            # Still waiting for the status to update from the game.
            # This signals executeQueue to re-queue the command and wait another tick.
            return False

       
    
    def confirmRaceStart(self): #copy sto
        """
        Sends the formation command (3) and waits for the game status to confirm "Formation".
        """
        # --- State 1: Initiation (Only runs once) ---
        if self.startingRace == False:
            self.startingRace = True
            
            # 1. Initiate the API call to stop the race
            api_result = self.api_set_race(3) # 0 = stop
            print(f"Initiated Race Start via API. Result: {api_result}. Starting confirmation process.")
            
            if api_result is False or api_result is None:
                # The API call itself failed (connection/timeout). 
                # executeQueue will catch this failure and retry the command.
                self.startingRace = False # Reset flag for next retry
                return api_result 

            # API call succeeded. Now fall through to the monitoring state for the next tick.
            # Returning False here is technically correct as we are now WAITING, 
            # but to keep the flow clean, we let the next section handle the check.

        # --- State 2: Monitoring (Runs until raceStatus is "Stopped") ---
        # This executes on the next tick after the API call, and continues every tick thereafter.
        if self.raceStatus == "Formation":
            print("Race Start confirmed by game status.")
            self.startingRace = False # Crucial: Reset the flag upon success
            return True # Success!
        else:
            # Still waiting for the status to update from the game.
            # This signals executeQueue to re-queue the command and wait another tick.
            return False
    


    def checkDeletionStatus(self):
        """
        Checks live car data to confirm all cars have been deleted.
        Should be called repeatedly while self.deletingRacers is True.
        """
        
        # Assumes self.current_car_data is updated in onUpdate
        car_data = getattr(self, 'current_car_data', [])
        
        if len(car_data) == 0:
            # Success: Deletion confirmed
            self.deletingRacers = False
            #print("Deletion confirmed: 0 cars on field.")
            return True # Command succeeded, return True
        else:
            # Failure: Still waiting
            print(f"Waiting for deletion... {len(car_data)} cars remaining.")
            return False # Command failed (to complete), return False
        
    def deleteRacers(self):
        """
        Initiates the API call to delete all racers, then monitors the car count
        until it reaches zero. Returns False to signal multi-tick waiting.
        """
        
        # --- State 1: Initiation (Only runs once) ---
        if self.deletingRacers == False:
            self.deletingRacers = True
            api_result = self.api_delete_all_racers()
            
            if api_result is False or api_result is None:
                # The API call itself failed (e.g., connection error). 
                # executeQueue will catch this failure and retry the command immediately.
                self.deletingRacers = False # Reset flag so next attempt will re-initiate the API call
                return api_result 
            
            print("Initiated deletion via API. Starting multi-tick confirmation process.")
            
            # If the API call succeeded (True), we fall through to the monitoring state
            # by letting the rest of the function run, which immediately hits the 'return False' block.

        # --- State 2: Monitoring (Runs until car count is zero) ---
        # This block executes if self.deletingRacers is True (either from the initiation above,
        # or from being re-queued by executeQueue).

        car_data = getattr(self, 'current_car_data', [])
        current_car_count = len(car_data)
        
        if current_car_count > 0:
            # Still waiting for cars to despawn.
            # This signals executeQueue to re-queue the command and wait another tick.
            return False 
        else:
            # Deletion complete! Final cleanup and signal success.
            print("Racer deletion confirmed complete. Resetting local lists.")
            
            # Housekeeping (Crucial for next race setup)
            self.deletingRacers = False
            self.usersEntered = []
            self.racer_names = []
            self.totalCars = 0
            
            # Signal success to the executeQueue
            return True
        
    def onLeave(self,command):
        """
        Handles a user leave command. Removes the user from the external API 
        and then ensures they are removed from the local usersEntered list.
        """
        userid = command.get('userid')
        username = command.get('username')
        if not userid:
            print("Error: Command missing 'userid'.")
            return False
        result = self.api_remove_racer(userid) # Will get populated by application.py
        # 2. Mutate the local list regardless of API success.
        #    It's usually safer to remove the user locally if the command was received,
        #    or, more accurately: if the API call was successful.
        if result: # Only proceed with local removal if the API reported success.
            # This list comprehension creates a NEW list containing only the dictionaries 
            # whose 'userid' does NOT match the leaving user's ID.
            newArr = [d for d in self.usersEntered if d.get('userid') != userid]
            self.racer_names.remove(username)
            # This is the actual list mutation (reassignment) that updates the instance variable.
            self.usersEntered = newArr
            self.totalCars = len(self.usersEntered)
            print(f"Removed user {userid}. Current usersEntered count: {len(self.usersEntered)}")
        else:
            # The API call failed. The user is still in the local list.
            print(f"Warning: Failed to remove user {userid} from API. User remains in local list.")
        return result
    
    def onSave(self, command):
        """
        Saves the user's intended car (blueprint, colors, etc.) stored in usersEntered
        to the user stats database. This uses the fixed parameters the user joined with.
        It preserves all existing stats (wins, points, best_lap_time) during the save operation.
        """
        user_id = command.get('userid')
        racer_username = command.get('username')
        
        if not user_id:
            print("ERROR: Cannot save car without a valid userid.")
            return False
            
        saved_bp = command.get('bp')
        saved_colors = command.get('colors')
        
        # 1. CHECK IF CAR CONFIGURATION WAS PROVIDED DIRECTLY
        if not saved_bp or not saved_colors:
            print("Car config missing from command. Searching accepted entries (usersEntered)...")
            found_racer_entry = None
            
            # Search self.usersEntered (the list of accepted, immutable racer entries)
            accepted_entries = getattr(self, 'usersEntered', []) 
            
            # Search by User ID (Primary lookup)
            for entry in accepted_entries:
                if str(entry.get('userid')) == str(user_id): 
                    found_racer_entry = entry
                    break
            
            # Search by Username (Secondary lookup)
            if not found_racer_entry:
                for entry in accepted_entries:
                    if entry.get('username', '').lower() == racer_username.lower(): 
                        found_racer_entry = entry
                        break
            
            # 2. HANDLE NOT FOUND
            if not found_racer_entry:
                print(f"ERROR: Could not find user {racer_username} in the accepted entries list. Saving failed.")
                return False
                
            # 3. USE FOUND ENTRY DATA
            saved_bp = found_racer_entry.get('bp')
            saved_colors = found_racer_entry.get('colors')
            
            if not saved_bp or not saved_colors:
                print(f"ERROR: Found entry for {racer_username}, but car data (bp/colors) was incomplete in usersEntered.")
                return False

        # 4. LOAD, UPDATE, AND SAVE STATS
        current_stats = self.grabUserStats()
        
        # Define the COMPLETE DEFAULT TEMPLATE for a new user
        default_stats_template = {
            'wins': 0, 
            'races_entered': 0, 
            'best_lap_time': self.MAX_LAP_TIME_SENTINEL,
            'podiums': 0,
            'points': 0,
            'saved_bp': None,
            'saved_colors': None
        }
        
        # Fetch the EXISTING stats for this user ID, or an empty dict if new.
        stats = current_stats.get(user_id, {})
        
        # Preserve Existing Stats: Merge defaults into existing stats (only adds missing keys)
        for key, default_value in default_stats_template.items():
            if key not in stats:
                stats[key] = default_value
                
        # CRITICAL UPDATE: Only overwrite the saved car fields with the new values.
        # All other historical metrics remain untouched.
        stats['saved_bp'] = saved_bp
        stats['saved_colors'] = saved_colors

        current_stats[user_id] = stats
        self.saveUserStats(current_stats)
        
        print(f"User {racer_username}'s car configuration saved successfully: BP={saved_bp}, Colors={saved_colors}.")
        return True

    def resetBestLaps(self):
        """
        Goes through all saved user stats and resets the 'best_lap_time' back to 
        float('inf'). This is used when the track is changed to ensure lap times 
        remain relevant.
        """
        print("Initiating reset of all user best lap times...")
        
        # 1. Load existing stats
        current_stats = self.grabUserStats()
        
        reset_count = 0
        
        # 2. Iterate and modify
        for user_id, stats in current_stats.items():
            # Check if the stats dictionary actually contains a best_lap_time key
            if 'best_lap_time' in stats:
                # Reset the time to infinity (or a very large number)
                stats['best_lap_time'] = self.MAX_LAP_TIME_SENTINEL
                reset_count += 1
                
        # 3. Save the modified stats
        if reset_count > 0:
            self.saveUserStats(current_stats)
            print(f"Successfully reset best lap times for {reset_count} users.")
        else:
            print("No user stats found or no 'best_lap_time' field to reset.")

        return True

    
    def onFinish(self,data): # Called onUpdate which includes live finish data
        self.usersEntered
        finish_data = data['finish_data']
        POINTS_STRUCTURE = [15, 12, 10, 8, 7, 6, 5, 4, 3, 2]  # all entered racers get at least 1
        # Check if all known cars have finished
        if len(finish_data) > 2: #if data not switched
            if self.obs_cur_scene not in  ["Race Finish", "Season Standings"]: # switch scene to race finish
                self.obs_switch_scene("Race Finish")

        if len(finish_data) == self.totalCars and self.totalCars > 0 and not self.raceFinished: # All racers finished
            print("Finished Race")
            self.obs_finish_timer = FINISH_SCREEN_LENGTH
            self.obs_finish_timerRunning = True
            if self.obs_cur_scene not in ["Race Finish", "Season Standings"]: # switch scene to race finish
                self.obs_switch_scene("Race Finish")

            current_stats = self.grabUserStats()
            race_best_lap = self.MAX_LAP_TIME_SENTINEL
            race_best_racer_name = None
            race_winner_name = None
            
            for racer_result in finish_data:
                user_id = racer_result['owner'] # unfortunate misnomer but temporary workaround
                place = int(racer_result.get('pos', len(finish_data) + 1)) # Default to last place if missing
                racer_name = racer_result['name'] # Get name for easy use
                # Initialize or retrieve user stats
                stats = current_stats.get(user_id, {
                    'name':racer_result['name'],
                    'wins': 0, 
                    'races_entered': 0, 
                    'best_lap_time': helpers.get_time_from_seconds(self.MAX_LAP_TIME_SENTINEL),
                    'podiums': 0, # NEW FIELD
                    'points': 0,  # NEW FIELD
                    'saved_bp': None,
                    'saved_colors': None
                })
                
                # 1. Update basic stats
                stats['races_entered'] = int(stats.get('races_entered', 0)) + 1
                
                # 2. Update Wins and Podiums
                if place <= 3:
                    stats['podiums'] = int(stats.get('podiums', 0)) + 1
                if place == 1:
                    stats['wins'] = int(stats.get('wins',0)) + 1
                    
                # 3. Update Points
                if 1 <= place <= 10:
                    # Points for places 1-10
                    points_to_add = POINTS_STRUCTURE[place - 1]
                elif place > 10 and place <= len(finish_data):
                    # 1 point for finishing outside the top 10
                    points_to_add = 1
                else:
                    points_to_add = 0
                
                curPoints = int(stats.get('points', 0))
                stats['points'] = curPoints + points_to_add

                best_lap_str = racer_result.get('bestLap')
                # Try to convert it to a float for comparison
                try:
                    best_lap_seconds = helpers.get_seconds_from_time(best_lap_str)
                except (TypeError, ValueError):
                    # Handle cases where it's None, "N/A", or a formatted string
                    best_lap_seconds = self.MAX_LAP_TIME_SENTINEL 
                    
                try: # Convert stat too
                    best_stat_lap_seconds = helpers.get_seconds_from_time(stats['best_lap_time'])
                except (TypeError, ValueError):
                    # Handle cases where it's None, "N/A", or a formatted string
                    best_stat_lap_seconds = self.MAX_LAP_TIME_SENTINEL 
                
                # 4. Update best lap
                # check if best lap stat is string formatted and convert that too
                if best_lap_seconds < best_stat_lap_seconds:
                    stats['best_lap_time'] = helpers.get_time_from_seconds(best_lap_seconds)
                
                current_stats[user_id] = stats
                if best_lap_seconds < race_best_lap: 
                    race_best_lap = best_lap_seconds 
                    race_best_racer_name = racer_name

                if place == 1:
                    race_winner_name = racer_name

            self.saveUserStats(current_stats) # Save updated stats
            self.total_season_racers = len(current_stats)

            # --- Ticker Updates based on Race Results ---
            
            # Check for new Global Track Record
            # self.best_lap_time is a string, so we need to convert it back to a float for comparison
            current_global_best = helpers.get_seconds_from_time(self.best_lap_time) if self.best_lap_time != "N/A" else self.MAX_LAP_TIME_SENTINEL
            
            if race_best_lap < current_global_best:
                print(f"NEW TRACK RECORD! {race_best_lap:.2f}s by {race_best_racer_name}")
                self.best_lap_time = helpers.get_time_from_seconds(race_best_lap)
                self.best_lap_racer = race_best_racer_name

            # Update Last Winner
            if race_winner_name:
                self.resolve_twitch_prediction(race_winner_name)
                self.last_winner = race_winner_name
                print(f"Race Winner: {self.last_winner}")
            
            # 5. TRIGGER RACE RESET COUNTDOWN
            self.raceFinished = True
            self.raceFinishCountdown = RACE_FINISH_DELAY
            
        else:
            pass # Continue waiting for all cars to finish
        

    def delay(self): # delays (empty function to delay command execution if required)
        print("delay")

    def resetRace(self):
        print("\n--- Initiating Race Reset Sequence ---")
        self.freshStart = True
        self.autoFilling = False
        self.autoStarted = False
        self.raceStartCountdown = RACE_START_DELAY
        self.autoStartCountDown = AUTO_START_DELAY
        self.autoStartTimerRunning = False
        self.raceFinished = False
        self.totalCars = 0 # Here to stop autorace from triggering prematurely. Need a better way to do this
        self.confirmedSpawns = {}  # clear out known spawners
        self.obs_intro_timer = -1
        self.obs_intro_timerRunning = False
        self.obs_finish_timer = -1
        self.obs_finish_timerRunning = False
        # 1. Stop the race
        #self.commandQueue.append(self.stopRace)

        self.commandQueue.append(self.deleteRacers)

        self.commandQueue.append(self.confirmRaceStop)

        ## 2. Request deletion and set 'deletingRacers' flag
        #self.commandQueue.append(self.deleteRacers)
        
        # 3 Reset race control
        self.commandQueue.append(self.resetRaceControl)

        # delay??
        self.commandQueue.append(self.openEntries)
        
        # 5. Reset the start countdown

        # 6. Refund any active prediction points
        if self.prediction_active:
            self.cancel_twitch_prediction()
            print("Twitch Prediction canceled (points refunded).")
        self.autoStarted = False # TODO: Creaqte a confirmrace reset that essentially only resets timer and such after deletion is confirmed

        # 7. Switch obs scene to intro again (Keep at season until next joiner)
        #if self.obs_cur_scene != "Intro Display":
        #    self.obs_switch_scene("Intro Display")

    def _reset_deletingRacers_state(self):
        self.deletingRacers = False
        # Also reset any other related temporary flags

    def _reset_stoppingRace_state(self):
        self.stoppingRace = False
        # Also reset any other related temporary flags

    def _reset_startingRace_state(self): # Race going to formation
        self.startingRace = False
        # Also reset any other related temporary flags


    def executeQueue(self):
        """
        Executes one command from the queue. Handles success, failure, and state-waits.
        If a wait times out, attempts to dynamically reset the command's internal state
        to force a fresh API call on the next retry.
        """
        if not self.commandQueue:
            return

        command = self.commandQueue.pop(0) # FIFO
        command_name = command.__name__ 
        
        current_failures = self.commandFailures.get(command_name, 0)
        current_restarts = self.commandRestarts.get(command_name, 0)
        try:
            result = command()
            
            # --- Multi-Tick Waiting Logic ---
            if result is False:
                # Command execution requires another tick to complete (WAITING FOR STATE CHANGE)
                self.commandQueue.insert(0, command)
                
                # Use the failure counter to detect if the *waiting* state is timing out
                self.commandFailures[command_name] = current_failures + 1 
                
                if self.commandFailures[command_name] >= self.MAX_QUEUE_FAILURES:
                    # If the waiting period is exhausted, raise an exception to trigger the retry/abandon logic
                    raise Exception("Multi-tick command wait timed out.")
                
                print(f"Command '{command_name}' is waiting for state change. Re-queueing (Wait Attempt {self.commandFailures[command_name]}/{self.MAX_QUEUE_FAILURES}).")
                return 

            # --- Standard API Failure Check (The command returned a specific error) ---
            if result is None:
                raise Exception("API or Command execution reported specific failure.")

            # --- Command Succeeded ---
            print(f"Command '{command_name}' succeeded.")
            self.commandFailures[command_name] = 0 # Reset failure count
                

        except Exception as e:
            # Standard Failure/Timeout Logic
            is_wait_timeout = "wait timed out" in str(e).lower()
            self.commandFailures[command_name] = current_failures + 1
            
            if self.commandFailures[command_name] >= self.MAX_QUEUE_FAILURES:
                if is_wait_timeout and current_restarts < self.MAX_RESTART_RETRIES:
                    # 1. We timed out waiting for the game state, AND we have retries left.
                    print(f"CRITICAL STATE DRIFT: '{command_name}' failed. Restarting API call (Attempt {current_restarts + 1}/{self.MAX_RESTART_RETRIES}).")
                    
                    # Increment the dedicated restart counter
                    self.commandRestarts[command_name] = current_restarts + 1
                    
                    # Reset the *API Failure* counter so the new API call gets a fresh set of retries.
                    self.commandFailures[command_name] = 0
                    
                    # --- Dynamic State Reset ---
                    if command_name == "deleteRacers":
                        self._reset_deletingRacers_state()
                    elif command_name == "confirmRaceStop":
                        self._reset_stoppingRace_state()
                    elif command_name == "confirmRaceStart":
                        self._reset_startingRace_state()
                        
                    # Re-queue the command for a fresh attempt (starts from State 1: API Call)
                    self.commandQueue.insert(0, command)
                else:
                    # 2. Hard Failure: Either we ran out of simple retries, OR we ran out of full restarts.
                    print(f"CRITICAL ERROR: Command '{command_name}' ABANDONED after reaching maximum failure/restart limits. Details: {e}")
                    
                    # Clean up both counters for the abandoned command
                    self.commandFailures[command_name] = 0
                    self.commandRestarts[command_name] = 0 
                    # ***ACTION ITEM: Log this error and alert the streamer!***
                
            else:
                # Standard retry logic (not yet at MAX_QUEUE_FAILURES)
                print(f"ERROR: Command '{command_name}' failed ({e}). Re-queueing (Attempt {self.commandFailures[command_name]}/{self.MAX_QUEUE_FAILURES}).")
                self.commandQueue.insert(0, command)
        
    def autoStart(self): 
        """
        Closes entries, resets auto-start flags, and queues the race launch commands.
        This function should only be called when autoStartCountDown <= 0.
        """
        print("--- Initiating Auto Race Start Sequence ---")
        
        # Check 1: Ensure we are in a safe, stopped state before proceeding
        if self.raceStatus != "Stopped" or self.autoStarted == True:
            print(f"Failed attempt to autostart: Race is currently in status '{self.raceStatus}' (autoStarted={self.autoStarted}). Skipping launch.")
            # Send stopRace comand?
            return False
            
        # --- 1. State Resets ---
        # Reset the short auto-start timer flags and counter for the next race cycle.
        self.autoStartTimerRunning = False 
        self.autoStartCountDown = AUTO_START_DELAY 
        
        # Ensure the master timer is reset, in case it wasn't already.
        # self.raceStartCountdown = INITIAL_PREP_DELAY # Assuming you have a constant for this

        # --- 2. Twitch Integration ---
        if len(self.racer_names) >= 2:
            print("Starting Twitch Prediction...")
            self.start_twitch_prediction()
        else:
            print("Not enough racers for a Twitch Prediction (min 2). Skipping.")
            
        # --- 3. Finalize and Launch Race Commands ---
        
        # Queue: 1. Close Entries (if necessary)
        if self.entriesOpen:
            print("Queueing closeEntries command.")
            self.commandQueue.append(self.closeEntries)
            
        # Queue: 2. Start Race
        print("Queueing startRace command.")
        self.commandQueue.append(self.confirmRaceStart)
        
        # --- 4. Final State Lock and Audio/Visuals ---
        play_dynamic_music("START") 
        self.autoStarted = True
        self.obs_intro_timerRunning = True
        self.obs_intro_timer = INTRO_SCREEN_LENGTH
        
        print("Race launch commands successfully queued.")
        # Fix 
        return True

    def checkDiscrepancy(self, data):
        if self.deletingRacers: #immediately no
            return
        """
        Checks for a mismatch between the number of expected racers (usersEntered)
        and the actual cars currently loaded in the simulation (carData).
        Also looks for two of the same username
        """
        carData = data
        #numCarsOnField = len(carData)
        #numCarsEntered = len(self.usersEntered)

        spawned_ownerids = {str(car.get('owner')) for car in carData if car.get('owner') is not None} # For some reason  
        #duped = [str(car.get('owner')) for car in carData if car.get('owner') is not None]
        #dupeSpawn = [str(car.get('userid')) for car in self.usersEntered if car.get('userid') is not None]
        
        #print()
        #print("Known:",len(spawned_ownerids),numCarsOnField)
        #print("Spawned:",len(duped),numCarsOnField)
        #print("confirmed:",len(self.confirmedSpawns),numCarsOnField)
        #print("entered:",len(dupeSpawn),numCarsEntered)
        #print()
        #print()
        
        # check if more than one is spawned and why
        for racer in self.usersEntered:
            user_id = racer.get('userid')
            str_user_id = str(user_id)
            if str_user_id not in spawned_ownerids:
                last_seen_time = self.confirmedSpawns.get(str_user_id)
                # 1. Is the car a KNOWN ENTITY that was just lost for a moment?
                if last_seen_time is not None and (time.time() - last_seen_time) < self.grace_period:
                    # Car was confirmed present very recently. Ignore the missing tick.
                    #print("Missing but grace:",str_user_id,duped)
                    continue
                last_spawn_time = self.pendingSpawns.get(str_user_id)
                if last_spawn_time is not None and (time.time() - last_spawn_time) < self.respawn_cooldown:
                    # A spawn was previously sent. Check the time elapsed.
                    # Still within the grace period for the game to load the car
                    #print(f"Ignoring missing car {user_id}: Waiting for spawn confirmation.")
                    continue
                else:
                    #print(f"TIMEOUT: Spawn for {str_user_id} failed to spawn in game. Re-sending spawn command.") # Comment this out
                    pass
                print(f"Fixing Discrepancy: Respawning racer {racer.get('username')}",racer.get('userid'))
                self.respawn_twitch_racer(racer)
                    # The car is still missing after the cooldown! It failed to spawn.

    

    def onUpdate(self,data):
        """
        processes new realtime data every data output tick  (~ 4-5 times per second)
        Performs timed based race managment functions

        Ultimate goal is to have automated system that: 
        1. automatically opens entries upon start and resets
        2. closes entries based off of either time or capacity
        3. starts the race, 
        4. Detects when race finishes, has short delay and then resets race to start cycle again 
        """
        if self.enabled == False: # Just dont run loop
            return 
        carData = data['realtime_data'] # Contains list of all cars loaded into simulation, includes name, speed, location, much more
        #detect changes here
        self.current_car_data = carData # Store the latest car data for access by other functions
        numCars = len(carData)

        self.raceStatus = data['meta_data']['status']
        laps_left = data['meta_data']['lapsLeft']
        if self.lapsLeft != laps_left:
            self.next_race_time = self._approximate_next_race(carData)  # Next Race appoximation
        self.lapsLeft = laps_left
        self.timer += 1


        # --- DYNAMIC MUSIC CONTROL ---
        # 1. Check for the most urgent states first (e.g., race end, final lap)
        if self.raceFinished or self.stoppingRace:
            # Race is over, playing the cooldown/reset music
            play_dynamic_music("RESET")
            
        elif self.raceStatus == "Green Flag" and not self.stoppingRace:
            # Race is actively running
            if self.lapsLeft <= 0: # Need check for if bogus data (crashfix)
                play_dynamic_music("FINAL")
            else:
                # Standard Race Music
                play_dynamic_music("RACE")
                
            # Logic for manually started race remains here
            if self.autoStarted == False:
                print("determining autostart")
                self.autoStarted = True
                self.autoStartTimerRunning = False
                self.autoStartCountDown = AUTO_START_DELAY
                self.closeEntries()
                self.start_twitch_prediction()
            
        elif self.entriesOpen:
            # Entries are open, playing the prep/lobby music
            play_dynamic_music("PREP")
            
        elif self.raceStatus in ["Formation"]:
            play_dynamic_music("START")
        
        check_music_finished_and_loop()
        # -----------------------------


        # Dynamic OBS scene control:
        if self.obs_intro_timerRunning: # Runs Intro display until ? ammount of seconds after race "starts" (is in formation)
            self.obs_intro_timer -= 1
            if self.obs_intro_timer < 0 and self.obs_intro_timerRunning:
                if self.obs_cur_scene != "Race Splits":
                    self.obs_switch_scene("Race Splits")
                    self.obs_intro_timerRunning = False
                    obs_intro_timer = RACE_START_DELAY

        if self.obs_finish_timerRunning: # Keeps Race Finish Display on unitl ? ammount of seconds after race finishes, then shows season until reset
            self.obs_finish_timer -= 1
            if self.obs_finish_timer < 0 and self.obs_finish_timerRunning:
                if self.raceStatus != "Stopped": # also doubles as race stopper to prevent accidental green flag leaks
                    #self.commandQueue.append(self.deleteRacers) Delete here??
                    self.commandQueue.append(self.confirmRaceStop) # auto starts even to

                if self.obs_cur_scene != "Season Standings":
                    self.obs_switch_scene("Season Standings")
                    self.obs_finish_timerRunning = False
                    self.obs_finish_timer = RACE_FINISH_DELAY

        if self.pendingSpawns:
            # Create a set of user IDs that are currently on the field
            current_field_ids = {str(car.get('owner')) for car in carData if car.get('owner') is not None} 
            for user_id in current_field_ids:
                self.confirmedSpawns[user_id] = time.time()
                foundCar = self.pendingSpawns.pop(user_id, None)
                #if foundCar: # Debug
                    #print(f"Pending spawn {user_id} now on field.",len(self.pendingSpawns))
        
    
        self.checkDiscrepancy(carData)
        self.overlay_data = self.build_overlay_data()
        if self.raceFinishCountdown == 0 and self.raceFinished: # Reset race
            self.resetRace()

        if len(self.commandQueue) > 0:          
            self.executeQueue()

        if self.raceFinished == False:
            self.onFinish(data)
        
        # New decision tree:
        # --- PHASE 1: Main Race Entry/Prep Countdown ---
        #print(self.raceStartCountdown,self.entriesOpen,self.totalCars)
        #print(self.autoStarted,self.entriesOpen,self.raceStartCountdown,self.totalCars)
        if self.autoStarted == False and self.entriesOpen == True and self.raceStartCountdown > 0 and self.totalCars >= 1: 
            # Timer is running and we are accepting entries
            self.raceStartCountdown -= 1
            
            
            if self.raceStartCountdown % 40 == 0 or self.raceStartCountdown < 3: 
                print("Race Start in:",self.raceStartCountdown)
                
        else:
            #print("phase 1 fall through")
            if self.raceStatus in ["Green Flag","Formation","Finished"]:
                self.stream_timer_output = self.raceStatus
            else: 
                #print(self.autoStarted,self.entriesOpen,self.raceStartCountdown,self.totalCars)
                self.stream_timer_output = "Def1" #self.raceStatus
            # If the main countdown block's conditions fail (either countdown is 0, or entries closed, etc.)
           
                        
                        
        # --- PHASE 2: Countdown Finished (self.raceStartCountdown == 0) ACTIONS ---
        # This condition ensures we only run if the entry countdown is done and the race isn.t active
        if self.raceStartCountdown == 0 and self.autoStarted == False and not self.stoppingRace: 
            
            current_count = len(self.usersEntered) # Use a reliable, current count (self.totalCars)
            
            # 1. AUTOFill Logic (Initiation)
            # Check if auto-fill is enabled AND we are below capacity AND not already filling
            if self.autoFill and current_count < RACE_CAPACITY and not self.autoFilling:
                print("Auto-filling bots initiated.",self.raceStatus)
                # Call the function. It queues the spawns and sets self.autoFilling = True
                self.auto_fill_racers() 

            # 2. AUTOFill Monitoring (Wait for the queued spawns to register)
            if self.autoFilling:
                # Check if the required number of cars has been registered by the game/spawn queue
                if current_count >= RACE_CAPACITY and numCars >= RACE_CAPACITY:
                    # Capacity met! Transition to the start timer.
                    print("Capacity reached after auto-fill. Stopping fill state.")
                    self.autoFilling = False  # Clear the state flag
                else:
                    # Still filling, must wait for the next tick
                    self.stream_timer_output = "FILLING BOT OPPONENTS"
                    return # IMPORTANT: Exit this tick to wait for the count to increase.


            # 3. AUTO-START Logic (Only runs if autoFilling is False and we meet start criteria)
            # Start the timer if:
            # A) We reached RACE_CAPACITY (which just happened if autoFilling was true)
            # OR B) The main timer ran out and we have at least one racer (the minimum start requirement)
            if numCars >= RACE_CAPACITY or numCars >= 1 and not (self.stoppingRace or self.deletingRacers):
                
                # A. Initialize the autoStartCountDown (the final short delay)
                if self.autoStartTimerRunning == False:
                    self.autoStartTimerRunning = True
                    print("Minimum start requirement met. Initializing short auto-start timer.")
                    
                # B. Tick and Execute the autoStartCountDown
                if self.autoStartTimerRunning:
                    self.autoStartCountDown -= 1
                    
                    # Optional: Update stream status to reflect the short delay
                    #self.stream_timer_output = self.get_stream_timer_output(self.autoStartCountDown,"STARTING IN:")
                    
                    if self.autoStartCountDown <= 0:
                        print("Starting race via autostart.")
                        self.autoStart()
                        # self.autoStart() must handle resetting autoStartCountDown 
                        # and setting self.autoStarted = True.

        # If we get here and the race hasn't started, the system waits at the "WAITING FOR RACERS" state
        # until the `numCars` count changes or a manual start occurs.capacity is met or manually started.
            
            
        # --- PHASE 3: Race Finished Countdown (Looks good) ---
        if self.raceFinished and self.raceFinishCountdown > 0:
            if self.finishTimerRunning == False: # Fixed: Check if it's NOT running before setting to True
                self.finishTimerRunning = True
            self.raceFinishCountdown -= 1
            self.stream_timer_output = self.get_stream_timer_output(self.raceFinishCountdown, 
                                    state_prefix="Race Resets in:")
            
            if self.raceFinishCountdown % 20 == 0 or self.raceFinishCountdown < 3: 
                print("Race Reset in:",self.raceFinishCountdown)

        # --- PHASE 4: Stream Status Update (Refined) ---
        # Check if race is NOT finished AND autoStart is NOT yet executed
        if not self.raceFinished and not self.autoStarted: 
            #print("whut doint",self.autoFilling,self.raceStartCountdown,numCars,self.stream_timer_output)
            if self.autoFilling:
                self.stream_timer_output = "FILLING BOT OPPONENTS"
            elif self.raceStartCountdown > 0:
                if numCars > 0 and self.totalCars > 0: # If theres a car running, start countdown to entries closed/race start
                    self.stream_timer_output = self.get_stream_timer_output(self.raceStartCountdown, state_prefix="Entries Close in:")
                else:
                    self.stream_timer_output = "WAITING FOR RACERS"
            elif self.raceStartCountdown == 0 and self.autoStartTimerRunning == False:
                self.stream_timer_output = ""
            elif self.autoStartTimerRunning:
                self.stream_timer_output = "RACE STARTING SHORTLY"
            elif self.raceStatus == "Green Flag": # or formation?
                self.stream_timer_output = "RACE IN PROGRESS"
            else: 
                # Default state (e.g., race stopped, waiting for start trigger, setup complete)
                print(self.totalCars,numCars)
                self.stream_timer_output = "Default (ERROR)" #self.raceStatus


        


    def getSimSettings(self,filename):
        try:
            with open(filename, 'r') as infile: 
                simSettings = json.load(infile)
                return simSettings
        except (FileNotFoundError, json.JSONDecodeError):
             print(f"Warning: Could not read {filename}. Using empty settings.")
             simSettings = {}
             return simSettings

        
    def updateSettings(self,key,value):
        settingsObject = self.getSimSettings(self.settingsFilename)
        if settingsObject.get(key) != None:
            settingsObject[key] = value
        try:
            with open(self.settingsFilename, 'w') as outfile: 
                json.dump(settingsObject, outfile) # Write default settings
        except (FileNotFoundError, json.JSONDecodeError):
             print(f"Warning: Could not open {self.settingsFilename}. Retry?")
             return False
        return True


    def update_text_overlay_files(self):
        """
        Writes the current race status and racer count to local text files.
        This function is now DEPRECATED. All overlay data is in 'overlay_data.txt'.
        """
        pass # Function body is now empty/removed to prevent redundant file writes.

    def _get_entries_status_text(self):
        """Generates the text for the entry status based on current state."""
        if self.entriesOpen:
            slots_left = RACE_CAPACITY - self.totalCars
            if slots_left <= 0:
                return 'ENTRIES FULL - RACE STARTING SOON'
            return f'ENTRIES OPEN - {slots_left} SLOTS LEFT'
        elif self.raceFinished:
            return 'RACE RESULTS'
        else: # Race in progress, formation, or waiting for reset
            return 'RACE IN PROGRESS - ENTRIES CLOSED'

    def get_overlay_data(self): # Kinda redundant...
        return self.overlay_data

    def get_stream_timer_output(self, countdown_value, state_prefix=""):
        """
        Writes the current countdown value and a descriptive prefix to a file 
        for the OBS text source.
        """
        newSeconds = self._get_seconds_from_ticks(countdown_value) # Semi accurately represents seconds out of updates per throttle
        if newSeconds != self.lastSeconds:
            self.lastSecond = newSeconds
            # Determine the text to write: e.g., "Race Starting in 30"
            if newSeconds > 0: #seconds
                output_text = f"{state_prefix} {newSeconds}"
            else:
                # When the timer hits zero, clear the text or display a final message
                output_text = "GO!" if "Starting" in state_prefix else ""            
        return output_text
    
    # Admin Controls
    def manual_open_entries(self, chatter_name="Admin"):
        """Admin command to manually open entries and reset the entry timer."""
        if self.entriesOpen:
            # Chat reply: Entries are already open!
            return f"@{chatter_name}, entries are already open!"
        self.openEntries()
        play_dynamic_music("PREP") # Transition music to Prep/Anticipation
        return f"@{chatter_name} manually OPENED entries. Join now with !join!"

    def manual_close_entries(self, chatter_name="Admin"):
        """Admin command to manually close entries and stop the timer."""
        if not self.entriesOpen:
            # Chat reply: Entries are already closed!
            return f"@{chatter_name}, entries are already closed!"
        self.closeEntries()
        # If there are racers, this should trigger the race start countdown logic in onUpdate
        return f"@{chatter_name} manually CLOSED entries. Race start countdown begins!"

    def manual_start_race(self, chatter_name="Admin"):
        """
        Admin command to immediately bypass the entry countdown and force the race to start.
        It triggers the final autoStart logic on the next tick.
        """
        
        # --- 1. Validation Checks ---
        if self.raceStatus != "Stopped" and self.raceStatus != "Pre-Race":
            # Allowing 'Pre-Race' (if that's a pre-start formation status) might be acceptable, 
            # but definitely stop if the race is active.
            return f"@{chatter_name}, the race is already {self.raceStatus}!"
            
        # Check 1: Minimum racers needed
        if len(self.usersEntered) < 2 and not self.autoFill: 
            return f"@{chatter_name}, you need at least 2 racers to start, and auto-fill is disabled!"
        
        # Check 2: If we are already running the main countdown, don't interfere
        if self.autoStarted: 
            return f"@{chatter_name}, the race sequence has already been started."
            
        # --- 2. Auto-Fill Execution ---
        # If autoFill is enabled and needed, manually trigger the process.
        if self.autoFill and len(self.usersEntered) < RACE_CAPACITY:

            # Call the initial queuing function. This sets self.autoFilling = True
            self.auto_fill_racers()
            
            # NOTE: If we are filling, the race won't start *immediately*. 
            # It will wait until the next tick confirms capacity is met.
            return f"@{chatter_name} manually started the fill process! Waiting for bots to spawn..."

        # --- 3. Bypass Timers and Trigger autoStart on next tick ---
        
        # A. Ensure the main entry countdown is zeroed out to meet Phase 2 condition
        self.raceStartCountdown = 0
        
        # B. Bypass the short auto-start timer (Phase 2, Step 3) by setting its countdown to zero.
        # The main loop will then call self.autoStart() on the next tick.
        self.autoStartCountDown = 0 
        
        # C. Ensure the timer flag is active so the main loop runs the countdown check.
        self.autoStartTimerRunning = True 
        
        # D. Close entries immediately to prevent further joins while we wait for the final tick.
        if self.entriesOpen:
            self.closeEntries()
        
        # Final Confirmation Message
        return f"@{chatter_name} force-starting race sequence. Launching next tick! 🚀"

    def manual_reset_race(self, chatter_name="Admin"):
        """Admin command to immediately reset all state."""
        # TODO: Failsafe/confirmation if race is running?
        self.resetRace() # Your existing function to reset all variables
        return f"@{chatter_name} manually issued a full race reset. New race cycle starting shortly."

    #------------ Twitch interactions---------

    def _make_twitch_api_call(self, method, url, payload):
        """Handles API calls and token refreshing."""
        # 1. Attempt the call
        response = method(url, headers=self._get_twitch_headers(), json=payload)

        # 2. Check for UNAUTHORIZED (Token Expired)
        if response.status_code == 401:
            print("Token expired (401). Attempting refresh...")
            # 3. Refresh the token
            if not self.refresh_twitch_token():
                # If refresh fails, we can't continue
                return response # Will still be the 401 response

            # 4. Retry the original call with the NEW token
            print("Token refreshed. Retrying API call...")
            response = method(url, headers=self._get_twitch_headers(), json=payload)

        return response

    def refresh_twitch_token(self):
        """Uses the refresh token to get a new access token."""
        url = "https://id.twitch.tv/oauth2/token"
        payload = {
            "client_id": self.TWITCH_CLIENT_ID,
            "client_secret": self.TWITCH_CLIENT_SECRET,
            "grant_type": "refresh_token",
            "refresh_token": self.TWITCH_REFRESH_TOKEN # Use the stored token
        }

        try:
            response = requests.post(url, data=payload)
            response.raise_for_status()
            data = response.json()
            # The new, fresh access token
            new_access_token = data["access_token"]
            self.TWITCH_ACCESS_TOKEN = new_access_token
            self.config_manager.set("TWITCH_ACCESS_TOKEN", new_access_token)            
            # You must update your storage with this new refresh token if it exists!
            if 'refresh_token' in data:
                new_refresh_token = data["refresh_token"]
                self.TWITCH_REFRESH_TOKEN = new_refresh_token
                self.config_manager.set("TWITCH_REFRESH_TOKEN", new_refresh_token)
            self.config_manager.save()

            print("Twitch Access Token refreshed successfully.")
            return True

        except Exception as e:
            print(f"Token refresh failed: {e}")
            return False
    def toggle_predictions(self): # enables/disables predictions
        self.predictions_enabled = not self.predictions_enabled
        print('Set predictions to',self.predictions_enabled)
        return True

    def manual_start_prediction(self,chatter_name="Admin"): # stub for now
        result = self.start_twitch_prediction()
        print("Manualy start prediction",chatter_name,result)
        return result

    def manual_refund_prediction(self,chatter_name="Admin"): # stub for now
        result = self.cancel_twitch_prediction()
        print("Manualy refunding prediction",chatter_name,result)
        return result


    def _get_twitch_headers(self):
        """Returns the standard headers required for Twitch Helix API calls."""
        return {
            "Client-ID": self.TWITCH_CLIENT_ID,
            "Authorization": f"Bearer {self.TWITCH_ACCESS_TOKEN}",
            "Content-Type": "application/json"
        }


    def start_twitch_prediction(self):
        if self.predictions_enabled == False:
            return 
        if self.prediction_active:
            print("Twitch Prediction is already active.")
            return

        # Use the names of racers currently entered
        if not self.racer_names: # Assume racer_names holds the list of entrants
             print("Cannot start prediction: No racers entered.")
             return
        
        # 🎯 FIX: Limit the outcomes to the first 10 racers (max allowed by Twitch) (TODO: Figure out good way to have people predict on all cars) because there may be instances where the car in list wins
        MAX_NAME_LENGTH = 25 # Twitch Rule
        MAX_INDIVIDUAL_OUTCOMES = 9 
        all_racers = list(self.racer_names) # Make a mutable copy

        # Ensure we have at least 2 total outcomes (1 individual + The Field)
        if len(all_racers) < 2:
            print("Cannot start prediction: Fewer than 2 total racers.")
            return

        # 1. Randomly select the individual racers
        random.shuffle(all_racers)
        individual_racers = all_racers[:MAX_INDIVIDUAL_OUTCOMES]

        # 2. Identify the remaining racers for the field
        field_racers = all_racers[MAX_INDIVIDUAL_OUTCOMES:]

        # 3. Build the outcomes list
        outcomes = [{"title": name[:MAX_NAME_LENGTH]} for name in individual_racers]

        # 4. Add "The Field" outcome if there are remaining racers
        if field_racers:
            outcomes.append({"title": FIELD_RACER_TITLE})

        # Store the final mapping for resolution later
        self.prediction_racer_map = {name: name for name in individual_racers}
        if field_racers:
            self.prediction_racer_map[FIELD_RACER_TITLE] = field_racers # Map the field name to a list of names

        # 2. Check minimum requirement after filtering
        if len(all_racers) < 2 or len(self.prediction_racer_map) < 2:
            print("Cannot start prediction: Fewer than 2 racers remain after applying prediction limit.")
            return
             
        title = "Who will win the next race?"
        prediction_window = 180 # 3 minutes for viewers to bet

        url = "https://api.twitch.tv/helix/predictions"
        
        payload = {
            "broadcaster_id": self.TWITCH_BROADCASTER_ID,
            "title": title,
            "outcomes": outcomes,
            "prediction_window": prediction_window 
        }
        print(payload)
        print(len(outcomes))
        try:
            #response = requests.post(url, headers=headers, json=payload)
            response = self._make_twitch_api_call(requests.post, url, payload) # <--- NEW
            response.raise_for_status()
            
            twitch_data = response.json().get('data', [{}])[0]
            self.prediction_id = twitch_data.get('id')
            self.prediction_active = True
            
            # Store the mapping for resolution later
            self.outcome_map = {}
            for outcome in twitch_data.get('outcomes', []):
                self.outcome_map[outcome.get('title')] = outcome.get('id')

            print(f"Twitch Prediction STARTED successfully. ID: {self.prediction_id}")
            
        except Exception as e:
            status_code = response.status_code if 'response' in locals() else 'N/A'
            
            # Check if the response exists and has an error body
            if status_code == 400 and 'response' in locals():
                error_details = response.text 
                print(f"Error starting Twitch Prediction (Status: 400): {e}")
                print(f"Twitch Error Details: {error_details}") # <--- THIS IS THE KEY
            else:
                error_details = response.text 
                print(f"Error starting Twitch Prediction: {e}")
                print(f"Twitch Error Details: {error_details}") # <--- THIS IS THE KEY


    def resolve_twitch_prediction(self, winning_racer_name):
        """
        Resolves the active Twitch Prediction, declaring the winner and distributing points.
        Should be called immediately upon determining the race winner.
        """
        if not self.prediction_active or not self.prediction_id:
            print("No active prediction to resolve.")
            return

        # 1. Get the Twitch Outcome ID for the winner
        winning_outcome_id = self.outcome_map.get(winning_racer_name)
        winning_outcome_name = None

        # 1. Check if the winner was an individually named outcome
        if winning_racer_name in self.outcome_map:
            winning_outcome_name = winning_racer_name
            winning_outcome_id = self.outcome_map[winning_racer_name]
            
        # 2. Check if the winner was part of "The Field"
        else:
            field_racers = self.prediction_racer_map.get(FIELD_RACER_TITLE, [])
            if winning_racer_name in field_racers:
                winning_outcome_name = FIELD_RACER_TITLE
                # The field outcome was created using FIELD_RACER_TITLE
                winning_outcome_id = self.outcome_map.get(FIELD_RACER_TITLE) 

        if not winning_outcome_id:
            print(f"Error: Winner ({winning_racer_name}) was not found in prediction outcomes (Refund is necessary).")
            self.cancel_twitch_prediction()
            return

        # 2. Patch the prediction status to RESOLVED
        url = f"https://api.twitch.tv/helix/predictions"
        headers = self._get_twitch_headers()
        
        # Status RESOLVED ends the prediction and pays out the channel points
        payload = {
            "broadcaster_id": self.TWITCH_BROADCASTER_ID,
            "id": self.prediction_id,
            "status": "RESOLVED",
            "winning_outcome_id": winning_outcome_id 
        }

        try:
            response = self._make_twitch_api_call(requests.patch, url, payload) # <--- NEW
            response.raise_for_status()
            
            print(f"Twitch Prediction RESOLVED. Winner: {winning_racer_name}. Points distributed!")
            
        except Exception as e:
            status_code = response.status_code if 'response' in locals() else 'N/A'
            
            # Check if the response exists and has an error body
            if status_code == 400 and 'response' in locals():
                error_details = response.text 
                print(f"Error resolving  Twitch Prediction (Status: 400): {e}")
                print(f"Twitch Error Details: {error_details}") # <--- THIS IS THE KEY
            else:
                error_details = response.text 
                print(f"Error resolving Twitch Prediction: {e}")
                print(f"Twitch Error Details: {error_details}") # <--- THIS IS THE KEY
            
        finally:
            # Reset prediction state regardless of success/failure
            self.prediction_active = False
            self.prediction_id = None
            self.outcome_map = {}


    def cancel_twitch_prediction(self):
        """
        Cancels the active Twitch Prediction, refunding all Channel Points to bettors.
        """
        if not self.prediction_active or not self.prediction_id:
            print("No active prediction to cancel.")
            return

        url = "https://api.twitch.tv/helix/predictions"
        headers = self._get_twitch_headers()
        
        # Status CANCELED refunds all points and ends the prediction
        payload = {
            "broadcaster_id": self.TWITCH_BROADCASTER_ID,
            "id": self.prediction_id,
            "status": "CANCELED" 
        }

        try:
            response = self._make_twitch_api_call(requests.patch, url, payload) # <--- NEW
            response.raise_for_status()
            
            print(f"Twitch Prediction CANCELED. All points have been refunded.")
            
        except Exception as e:
            status_code = response.status_code if 'response' in locals() else 'N/A'
            
            # Check if the response exists and has an error body
            if status_code == 400 and 'response' in locals():
                error_details = response.text 
                print(f"Error Canceling  Twitch Prediction (Status: 400): {e}")
                print(f"Twitch Error Details: {error_details}") # <--- THIS IS THE KEY
            else:
                print(f"Error Canceling Twitch Prediction (Status: {status_code}): {e}")
            
        finally:
            # Reset prediction state variables
            self.prediction_active = False
            self.prediction_id = None
            self.outcome_map = {}
        

    #Bot Filling
    # Use the same lists defined for your simulation/chat processing
    # NOTE: Ensure ALL_BPS and ALL_COLORS are accessible (imported or defined)
    # Example: from readStream import ALL_BPS, ALL_COLORS 

    def auto_fill_racers(self):
        """
        Automatically fills remaining open race slots with dummy CPU racers
        up to the maximum capacity defined in SETTINGS.
        """
        capacity = RACE_CAPACITY
        current_count = len(self.usersEntered)
        
        slots_to_fill = capacity - current_count
        
        if slots_to_fill <= 0:
            print("Race already at capacity. No auto-fill needed.")
            self.autoFilling = False
            return

        print(f"Auto-filling {slots_to_fill} remaining slot(s) to reach capacity of {capacity}.")
        self.autoFilling = True
        self.stream_timer_output = "FILLING BOT OPONENTS"
        botNames = BOT_NAMES[:]
        random.shuffle(botNames)
        for i in range(1, slots_to_fill + 1):
            # --- 1. Generate Unique Name and ID ---
            # Use a high number for the UID/name to avoid conflicts with real chatters (Racer01, Racer02, etc.)
            fill_index = current_count + i 
            racer_name = botNames.pop(0) #TODO: pick random names from 20 name choice array Let displayshow "bot" if is_bot
            #print(racer_name,botNames)
            racer_uid = f"UID_{racer_name}"
            
            # --- 2. Randomize Car/Color ---
            body = random.choice(ALL_BPS) # Assuming self.ALL_BPS is available
            color1 = random.choice(ALL_COLORS) # Assuming self.ALL_COLORS is available
            
            # Ensure colors are unique for aesthetic variety
            color2 = random.choice(ALL_COLORS) 
            while color2 == color1:
                color2 = random.choice(ALL_COLORS)
            colorList = [color1,color2,"#222222"]
            # --- 3. Construct Racer Data Object ---
            new_racer_data = {
                'username': racer_name,
                'userid': racer_uid,
                'is_bot': True, # New flag to easily identify CPU racers
                'bp': body,
                'colors': ','.join(colorList)
            }

            # --- 4. Add to the Main Entrant List ---
            # Assuming you have a central list of racer objects/dicts
            result = self.onJoin(new_racer_data)
            time.sleep(0.25)
            #print(f"  -> Added {racer_name} ({body}, {color1}/{color2})",result)
        print(f"Auto-fill complete. Final racer count: {len(self.racer_names)}.")
       



    # OBS Stuff:
    def connect_to_obs(self):
        """Establishes connection to OBS and returns the client object."""
        try:
            ws = obsws(self.obs_url, self.obs_port, self.obs_pass)
            ws.connect()
            print("Successfully connected to OBS-WebSocket.")
            return ws
        except Exception as e:
            print(f"Failed to connect to OBS: {e}")
            return None

    def obs_switch_scene(self, scene_name):
        """Sends a request to OBS to switch to a specific scene."""
        ws = self.obs_client
        if ws:
            try:
                # The 'SetCurrentProgramScene' request changes the active scene
                ws.call(obs_requests.SetCurrentProgramScene(sceneName=scene_name))
                print(f"OBS scene switched to: {scene_name}")
                self.obs_cur_scene = scene_name
            except Exception as e:
                print(f"Error switching scene: {e}")
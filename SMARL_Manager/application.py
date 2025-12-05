import os, math
import requests
from flask import Flask, render_template, jsonify, url_for, request, g
import requests
import json
from flask_socketio import SocketIO
import sharedData
import logging
import helpers # Import from sharedData?
from RaceManager import RaceManager
from ConfigManager import ConfigManager
from FileWatcher import RaceDataPoller

ALLOWED_EXTENSIONS = set(['txt', 'pdf', 'png', 'jpg', 'jpeg', 'gif'])
app = Flask(__name__)
app.config['SECRET_KEY'] = 'NEWKEYhappydays_placeholder'

app = Flask(__name__)

# --- 1. Define the endpoint(s) you want to silence ---
SILENT_ENDPOINTS = ['/api/overlay_data','/socket.io','/static']
#logging.getLogger('werkzeug').disabled = True or this
class SilentWerkzeugFilter(logging.Filter):
    """A filter to silence specific endpoint access logs in Werkzeug."""
    def filter(self, record):
        # Werkzeug logs the request path in the log record message
        # Example message: '127.0.0.1 - - [10/Nov/2023 10:00:00] "GET /health_check HTTP/1.1" 200 -'
        
        # Check if the requested path is in our silent list
        for endpoint in SILENT_ENDPOINTS:
            # We check if the endpoint string exists in the log record message
            # This handles both 200 and error codes for that path
            if f' {endpoint} ' in record.getMessage():
                return False  # Return False to DISCARD the log record
        
        return True  # Return True to keep (process) the log record


# --- 2. Apply the Filter ---
def setup_silent_logger():
    # Flask uses the 'werkzeug' logger for access logs
    werkzeug_logger = logging.getLogger('werkzeug')
    
    # Apply our custom filter
    werkzeug_logger.addFilter(SilentWerkzeugFilter())

# Call this setup function after app creation, typically before running the app
setup_silent_logger()




socketio = SocketIO(app)
#sio = socketio.AsyncClient()
#smarl_starting_data = [] # Racer Data that gets updated after the game says so
_Racer_Data = []

# Filepaths 
dir_path = os.path.dirname(os.path.realpath(__file__))
main_path = dir_path
realtime_path = os.path.join(main_path,"JsonData/RaceOutput/raceData.json")
twitch_path =  os.path.join(main_path, "TwitchPlays")
Twitch_json = os.path.join(twitch_path, "BotData")
blueprint_base = os.path.join(Twitch_json, "Blueprints") #location for stored blueprints
chatter_data = os.path.join(Twitch_json, 'chatdata.json')
sim_settings = os.path.join(Twitch_json, 'settings.json')
STATS_FILENAME =  os.path.join(Twitch_json,"user_race_stats.json")
ALL_BPS = ["typea","typeb","typec","typed"]

def find_racer_by_id(id,dataList): #Finds racer according to id
    result = next((item for item in dataList if str(item["racer_id"]) == str(id)), None)
    #print(result)
    return result

# Helper functions
def get_car_data(racerID): # gets the individual data vars, just separated out because it was ran over and over again
    racerData = find_racer_by_id(str(racerID),sharedData._RacerData)
    tag = racerData['name'][0:4] # TODO: Have uniqe generation (if multi space, have one word represent from each space and thennext letter)
    name = racerData['name']
    colors = racerData['colors'].split(",")
    primary = str(colors[0])
    secondary = str(colors[1])
    tertiary = str(colors[2])
    owner = racerData['display_name'] #TODO: make difference between owner, sponsor, and logo
    return tag,name,primary,secondary,tertiary,owner


# Various Form classes

@app.route('/', methods=['GET','POST']) #Showsall possible overlays for quick picking
def index():
     
    return render_template('smarl_overlay_dashboard.html')
#TODO: FIGURE OUT GLOBAL STORAGE FOR FLASK TO BPUT THESE VARIABLES IN
_raceStatus = [] # Various Data that contains race status and laps left
_qualifyingData = [] # Collection of qualifying Data stored while server is up
_raceData = [] # All Race Data formatted as realtime_data, qualifying_data, finish_data, meta_data
_splitData={} #singular split
_finishData=[] # Contains information appended after a racer finishes


@socketio.on('getJson')
def handle_get_json(jsonData):
   print("getJson?")


@socketio.on('getQual')
def handle_get_qual(jsonData): # Grabs Qualification data (Post Qualification)
    global _qualifyingData
    #print("returning qualification Data")
    socketio.emit('qualData', _qualifyingData)

@socketio.on('getRace')
def handle_get_race(jsonData):
    global _raceData
    #print("Returning Race Data",_raceData)
    socketio.emit('raceData', _raceData)

@socketio.on('getTwitchStats')
def handle_get_stats(jsonData):
    stats = Race_Manager.grabUserStats()
    statsjson = json.dumps(stats)
    #print('handle get stats',stats,statsjson)
    #print("Returning Race Data",_raceData)
    socketio.emit('twitchStats', statsjson)

@socketio.on('getCurrentRaceData')
def handle_get_race_current_data(jsonData):
    print("Returning Race Data",sharedData._SpecificRaceData)
    socketio.emit('raceData',sharedData._SpecificRaceData)


@socketio.on('getFinish')
def handle_get_finish(jsonData):
    global _finishData
    #print("Returning Finish Data")
    Race_Manager.onFinish(jsonData)
    socketio.emit('finishData',_finishData)

@socketio.on('getStatus')
def handle_get_status(jsonData):
    global _raceStatus
    #print("Returning Status Data")
    #print()
    #print("STATUS!!!",_raceStatus)
    socketio.emit('statusData',_raceStatus)

@socketio.on('getSeason')
def handle_get_season(jsonData):
    print("Returning Season Data",sharedData._RacerData)
    socketio.emit('seasonData',sharedData._RacerData)

@socketio.on('statusPacket')
def handle_incoming_status(jsonData):
    print("Got status Packet")
    global _raceStatus
    _raceStatus = jsonData
    socketio.emit('statusData', jsonData)
    #print('')

@socketio.on('racePacket')
def handle_incoming_race(jsonData):
    global _raceData
    _raceData = jsonData
    print("emit raceData",jsonData)
    socketio.emit('raceData', jsonData)
    #print('')

@socketio.on('qualPacket')
def handle_incoming_qual(jsonData):
    global _qualifyingData
    print("Got Qual Packet")
    _qualifyingData = jsonData
    socketio.emit('qualData', jsonData)
    #print('')

@socketio.on('splitPacket')
def handle_incoming_split(jsonData):
    global _splitData
    print("Got split Packet")
    _splitData = jsonData
    socketio.emit('splitData', jsonData)
    #print('')

@socketio.on('finishPacket')
def handle_incoming_finish(jsonData):
    global _finishData
    #print("Got Finish Packet")
    _finishData = jsonData
    socketio.emit('finishData')
    #print('')


@socketio.on('dataPacket') # handles all universal data
def handle_incoming_data(jsonData):
    global _raceData
    #print("Got data Packet",jsonData)
    Race_Manager.onUpdate(jsonData)
    _raceData = jsonData
    socketio.emit('raceData', jsonData)
    #print('')



@socketio.on('gotRacerData') # just to check if its there
def handle_incoming_racerData(jsonData):
    print("Retrieving racerData") 
    jsonDataFile = open("racerData.json","r")
    print(jsonDataFile,"datafile?")
    jsonLine = json.load(jsonDataFile)
    #print(jsonLine)
    sharedData._RacerData = jsonLine
    global _Racer_Data
    _Racer_Data = jsonLine
    socketio.emit('seasonData', _Racer_Data)


# _________________________SMARL REALTIME Control API CODE _______________________________
@app.route('/api/receive_command',methods=['POST'])
def api_receive_command():
    command = request.get_json(force=True) # is actually text not json
    command = json.loads(command) # necessary??
    print("Recived command request",command,type(command))
    cmd = command['cmd']
    val = command['val']
    # could turn this into a association array and match the functions
    if cmd == "delMID": #delete racer by meta ID (Includes userid if twitch car)
        api_remove_racer(val)
    elif cmd == "delBID": # delete racer by body ID
        api_remove_car(val)
    elif cmd == "delALL": # deletes all raceers (both meta and non)
        api_delete_all_racers()
    elif cmd == "impLEG": # imports league by ID
        api_import_league(val)
    elif cmd == "impCAR":
        api_spawn_racer(val)
    elif cmd == "edtSES": # Edit session type (practice, Qualifying, Race, (Test?))
        api_edit_session(val)
    elif cmd == "setSES": # Sets session to (open,closed)
        api_set_session(val)
    elif cmd == "setRAC": # Set Race status to (Race status (red,formation, yellow, green))
        api_set_race(val)
    elif cmd == "resCAR" : # RESETS driver (Driver ID)
        api_reset_racer(val)
    elif cmd == "sesLAP" : # Sets session max laps
        api_set_session_laps(val)
    elif cmd == "racLAP" : # Sets race total laps
        api_set_race_laps(val)
    elif cmd == "racDRA" : # Sets race Draft
        api_edit_race_draft(val)
    elif cmd == "racHAN" : # Sets race handicap # 0 to disable
        api_edit_race_handicap(val)
    elif cmd == "setTIR" : # enables/disables tire wear
        api_set_tire_wear(val)
    elif cmd == "setFUE" : # enables/disables fuel usage
        api_set_fuel_usage(val)
    elif cmd == "edtTIR" : # edits tire usage multiplier
        api_edit_tire_wear(val)
    elif cmd == "edtFUE" : # edits fuel usage multiplier
        api_edit_fuel_usage(val)
    elif cmd == "resRAC" : # Resets Race
        api_reset_race() 
    elif cmd == "carPIT" : # Resets Race
        api_pit_racer(val)

        
    return "Done"



@app.route('/api/spawn_racer/<racer_id>', methods=['GET'])
def api_spawn_racer(racer_id):
    command ={
        'cmd': 'impCAR',
        'val': str(racer_id)
    } 
    results = sharedData.addToQueue([command])
    return "Done"

# Required fields for a valid join command
REQUIRED_FIELDS = ['userid', 'username', 'bp', 'colors'] 

@app.route('/api/join_twitch_race', methods=['POST'])
def join_twitch_race():
    try:
        # Attempt to parse JSON input safely
        command = request.get_json(force=True, silent=True)
        if not command:
            return jsonify({"error": "Invalid JSON or missing data"}), 400

        # Data Validation: Ensure all required fields are present
        if not all(field in command for field in REQUIRED_FIELDS):
            return jsonify({
                "error": "Missing required fields",
                "required": REQUIRED_FIELDS
            }), 400

    except Exception as e:
        # Catch unexpected parsing errors
        return jsonify({"error": f"Failed to process request data: {e}"}), 400

    # Business Logic: Call the RaceManager method
    result = Race_Manager.onJoin(command)

    if result is False:
        # Race_Manager returned False (e.g., entries closed or full capacity)
        return jsonify({
            "status": "Denied",
            "message": "Race entries are closed or capacity is full."
        }), 403  # 403 Forbidden is a good status for denied actions

    # Success
    return jsonify({
        "status": "Success",
        "message": "Racer queued for entry."
    }), 200


REQUIRED_LEAVE_FIELDS = ['userid', 'username'] # BP and colors later?
@app.route('/api/leave_twitch_race', methods=['POST'])
def leave_twitch_race(): #TODO: Fix and finish later
    try:
        # Attempt to parse JSON input safely
        command = request.get_json(force=True, silent=True)
        if not command:
            return jsonify({"error": "Invalid JSON or missing data"}), 400

        # Data Validation: Ensure all required fields are present
        if not all(field in command for field in REQUIRED_LEAVE_FIELDS):
            return jsonify({
                "error": "Missing required fields",
                "required": REQUIRED_LEAVE_FIELDS
            }), 400

    except Exception as e:
        # Catch unexpected parsing errors
        return jsonify({"error": f"Failed to process request data: {e}"}), 400

    # Business Logic: Call the RaceManager method
    result = Race_Manager.onLeave(command)

    if result is False:
        # Race_Manager returned False (e.g., Race Entries closed or user not in race)
        return jsonify({
            "status": "Denied",
            "message": "Race Leaving Denied"
        }), 403  # 403 Forbidden is a good status for denied actions

    # Success
    return jsonify({
        "status": "Success",
        "message": "Racer queued for removal."
    }), 200

@app.route('/api/set_predictions_enabled', methods=['GET'])
def set_predictions_enabled(): # Toggles predictions ability
    try:
        # Business Logic: Call the RaceManager method
        result = Race_Manager.set_predictions_enabled() # TODO: get the value that it was toggled to
        
        if result is False:
             # If Race_Manager were to return False on a specific failure
             return jsonify({
                "status": "Failure",
                "message": "Predictions setting failed due to internal error."
             }), 500
             
    except Exception as e:
        # Catch internal runtime exceptions during the set process
        return jsonify({
            "status": "Error",
            "message": f"An unhandled error occurred during predction set: {e}"
        }), 500

    # Success
    return jsonify({
        "status": "Success",
        "message": "Predictions have been toggled"
    }), 200


@app.route('/api/reset_twitch_laps', methods=['GET']) # Using GET for quick admin access
def reset_twitch_laps():
    try:
        # Business Logic: Call the RaceManager method
        result = Race_Manager.resetBestLaps() 
        
        # Race_Manager.resetBestLaps is designed to return True on completion/success
        if result is False:
             # If Race_Manager were to return False on a specific failure
             return jsonify({
                "status": "Failure",
                "message": "Best lap reset failed due to internal error."
             }), 500
             
    except Exception as e:
        # Catch internal runtime exceptions during the reset process
        return jsonify({
            "status": "Error",
            "message": f"An unhandled error occurred during reset: {e}"
        }), 500

    # Success
    return jsonify({
        "status": "Success",
        "message": "All user best lap records have been reset."
    }), 200

@app.route('/api/open_twitch_entries', methods=['GET']) #
def open_twitch_entries():
    try:
        # Business Logic: Call the RaceManager method
        result = Race_Manager.manual_open_entries() 
        
        if result is False:
             # If Race_Manager were to return False on a specific failure
             return jsonify({
                "status": "Failure",
                "message": "Open Entries failed due to internal error."
             }), 500
             
    except Exception as e:
        # Catch internal runtime exceptions during the process
        return jsonify({
            "status": "Error",
            "message": f"An unhandled error occurred during Entry Opening: {e}"
        }), 500

    # Success
    return jsonify({
        "status": "Success",
        "message": "Race Entries Opened."
    }), 200

@app.route('/api/close_twitch_entries', methods=['GET']) #
def close_twitch_entries():
    try:
        # Business Logic: Call the RaceManager method
        result = Race_Manager.manual_close_entries() 
        
        if result is False:
             # If Race_Manager were to return False on a specific failure
             return jsonify({
                "status": "Failure",
                "message": "Close Entries failed due to internal error."
             }), 500
             
    except Exception as e:
        # Catch internal runtime exceptions during the process
        return jsonify({
            "status": "Error",
            "message": f"An unhandled error occurred during Entry Closing: {e}"
        }), 500

    # Success
    return jsonify({
        "status": "Success",
        "message": "Race Entries Closed."
    }), 200

@app.route('/api/start_twitch_race', methods=['GET']) #
def start_twitch_race():
    try:
        # Business Logic: Call the RaceManager method
        result = Race_Manager.manual_start_race() 
        
        if result is False:
             # If Race_Manager were to return False on a specific failure
             return jsonify({
                "status": "Failure",
                "message": "Race Start failed due to internal error."
             }), 500
        else:
            print(result)
             
    except Exception as e:
        # Catch internal runtime exceptions during the process
        return jsonify({
            "status": "Error",
            "message": f"An unhandled error occurred during Race Start: {e}"
        }), 500

    # Success
    print(result)
    return jsonify({
        "status": "Success",
        "message": "Race Started."
    }), 200

@app.route('/api/reset_twitch_race', methods=['GET']) #
def reset_twitch_race():
    try:
        # Business Logic: Call the RaceManager method
        result = Race_Manager.manual_reset_race() 
        
        # Race_Manager.resetBestLaps is designed to return True on completion/success
        if result is False:
             # If Race_Manager were to return False on a specific failure
             return jsonify({
                "status": "Failure",
                "message": "Racee reset failed due to internal error."
             }), 500
             
    except Exception as e:
        # Catch internal runtime exceptions during the reset process
        return jsonify({
            "status": "Error",
            "message": f"An unhandled error occurred during reset: {e}"
        }), 500

    # Success
    return jsonify({
        "status": "Success",
        "message": "Twitch Race has been reset."
    }), 200


@app.route('/api/refund_twitch_prediction', methods=['GET']) #
def refund_twitch_prediction():
    try:
        # Business Logic: Call the RaceManager method
        result = Race_Manager.manual_refund_prediction() 
        
        # Race_Manager.resetBestLaps is designed to return True on completion/success
        if result is False:
             # If Race_Manager were to return False on a specific failure
             return jsonify({
                "status": "Failure",
                "message": "Racee reset failed due to internal error."
             }), 500
             
    except Exception as e:
        # Catch internal runtime exceptions during the reset process
        return jsonify({
            "status": "Error",
            "message": f"An unhandled error occurred during reset: {e}"
        }), 500

    # Success
    return jsonify({
        "status": "Success",
        "message": "Twitch Race has been reset."
    }), 200


REQUIRED_SAVE_FIELDS = ['userid', 'username'] # BP and colors later?
@app.route('/api/save_twitch_car', methods=['POST'])
def save_twitch_car():
    """
    Saves a user's current car blueprint and colors to their persistent stats.
    """
    try:
        # Attempt to parse JSON input safely
        command = request.get_json(force=True, silent=True)
        if not command:
            return jsonify({"error": "Invalid JSON or missing data"}), 400

        # Data Validation: Ensure all required fields are present
        if not all(field in command for field in REQUIRED_SAVE_FIELDS):
            return jsonify({
                "error": "Missing required fields for saving car.",
                "required": REQUIRED_SAVE_FIELDS
            }), 400

    except Exception as e:
        # Catch unexpected parsing errors
        return jsonify({"error": f"Failed to process request data: {e}"}), 400
    
    try:
        result = Race_Manager.onSave(command) 
    
    except Exception as e:
        # Catch internal runtime exceptions during the saving process
        print(f"Error during Race_Manager.onSave: {e}")
        return jsonify({
            "status": "Error",
            "message": f"An internal error occurred while saving car: {e}"
        }), 500

    if result is False:
        # Race_Manager returned False (e.g., failed I/O, missing userid)
        return jsonify({
            "status": "Failure",
            "message": "Car saving failed due to an internal I/O issue."
        }), 500  # 500 Internal Server Error is appropriate for I/O issues

    # Success
    return jsonify({
        "status": "Success",
        "message": f"Car configuration saved for user {command.get('username')}."
    }), 200

@app.route('/api/import_league/<league_id>', methods=['GET'])
def api_import_league(league_id): 
    print("Received request to import league Car",league_id)
    command ={
        'cmd': 'impLEG',
        'val': str(league_id)
    } 
    results = sharedData.addToQueue([command])
    return "Done"



@app.route('/api/edit_session/<session_type>', methods=['GET'])
def api_edit_session(session_type): 
    print("Received request to edit session",session_type)
    command ={
        'cmd': 'edtSES',
        'val': str(session_type)
    } 
    results = sharedData.addToQueue([command])
    return "Done"

@app.route('/api/set_session/<status>', methods=['GET'])
def api_set_session(status):
    print("Received request to edit session",status)
    command ={
        'cmd': 'setSES',
        'val': str(status)
    } 
    results = sharedData.addToQueue([command])
    return "Done"

@app.route('/api/set_race/<status>', methods=['GET'])
def api_set_race(status):
    command ={
        'cmd': 'setRAC',
        'val': str(status)
    } 
    results = sharedData.addToQueue([command])
    return "Done"


@app.route('/api/reset_racer/<racer_id>', methods=['GET'])
def api_reset_racer(racer_id):
    print("Received request to reset racer",racer_id)
    command ={
        'cmd': 'resCAR',
        'val': str(racer_id)
    } 
    results = sharedData.addToQueue([command])
    return "Done"


@app.route('/api/set_session_laps/<laps>', methods=['GET'])
def api_set_session_laps(laps):
    print("Received request to set session laps",laps)
    command ={
        'cmd': 'sesLAP',
        'val': str(laps)
    } 
    results = sharedData.addToQueue([command])
    return "Done"


@app.route('/api/set_race_laps/<laps>', methods=['GET'])
def api_set_race_laps(laps):
    print("Received request to edit race laps",laps)
    command ={
        'cmd': 'raceLAP',
        'val': str(laps)
    } 
    results = sharedData.addToQueue([command])
    return "Done"


@app.route('/api/edit_race_draft/<value>', methods=['GET'])
def api_edit_race_draft(value):
    print("Received request to edit race draft value",value)
    command ={
        'cmd': 'racDRA',
        'val': str(value)
    } 
    results = sharedData.addToQueue([command])
    return "Done"


@app.route('/api/edit_race_handicap/<value>', methods=['GET'])
def api_edit_race_handicap(value):
    print("Received request to edit race handicap",value)
    command ={
        'cmd': 'racHAN',
        'val': str(value)
    } 
    results = sharedData.addToQueue([command])
    return "Done"


@app.route('/api/set_tire_wear/<enabled>', methods=['GET'])
def api_set_tire_wear(enabled):
    print("Received request to enable tire wear",enabled)
    command ={
        'cmd': 'setTIR',
        'val': str(enabled)
    } 
    results = sharedData.addToQueue([command])
    return "Done"

@app.route('/api/edit_tire_wear/<value>', methods=['GET'])
def api_edit_tire_wear(value):
    print("Received request to edit tire wear mult",value)
    command ={
        'cmd': 'setTIR',
        'val': str(value)
    } 
    results = sharedData.addToQueue([command])
    return "Done"


@app.route('/api/set_fuel_usage/<enabled>', methods=['GET'])
def api_set_fuel_usage(enabled):
    print("Received request to enable fuel usage",enabled)
    command ={
        'cmd': 'setFUE',
        'val': str(enabled)
    } 
    results = sharedData.addToQueue([command])
    return "Done"

@app.route('/api/edit_fuel_usage/<value>', methods=['GET'])
def api_edit_fuel_usage(value):
    print("Received request to edit fuel use mult",value)
    command ={
        'cmd': 'edtFUE',
        'val': str(value)
    } 
    results = sharedData.addToQueue([command])
    return "Done"



@app.route('/api/reset_race', methods=['GET'])
def api_reset_race(): # For cars without metadat
    print("Received request to reset race")
    command ={
        'cmd': 'resRAC',
        'val': 'all'
    } 
    results = sharedData.addToQueue([command])
    return "Done"



@app.route('/api/pit_racer',methods=['GET','POST']) # Maybe shouldnt be a route? todo: processt post data
def api_pit_racer(pit_data): #manually pits racer witch whatever data its current lp
    print("pitting racer",pit_data)
    command ={
        "cmd": "pitCAR",
        "val": pit_data #json stringify?
    } 
    print("sending",command)
    results = sharedData.addToQueue([command])

@app.route('/api/update_tuning_data',methods=['GET'])
def api_update_tuning():
    print("Received request to Update Tuning Data")
    #results = sharedData.addToQueue([command]) if we want to do live tune changes
    sharedData.update_tuning_data()
    return "Done"



@app.route('/api/remove_racer/<racer_id>', methods=['GET'])
def api_remove_racer(racer_id):
    print("Received request to Remove racer",racer_id)
    command ={
        'cmd': 'delMID',
        'val': str(racer_id)
    } 
    results = sharedData.addToQueue([command])
    return "Done"


@app.route('/api/remove_car/<car_id>', methods=['GET'])
def api_remove_car(car_id): # For cars without metadat
    print("Received request to Remove Car",car_id)
    command ={
        'cmd': 'delBID',
        'val': str(car_id)
    } 
    results = sharedData.addToQueue([command])
    return "Done"


@app.route('/api/remove_car/<car_id>', methods=['GET'])
def api_delete_racer(car_id): # For cars without metadat
    print("Received request to Remove Car",car_id)
    command ={
        'cmd': 'delBID',
        'val': str(car_id)
    } 
    results = sharedData.addToQueue([command])
    return "Done"

@app.route('/api/remove_all',methods=['GET'])
def api_delete_all_racers( ): # For cars without metadat
    command ={
        'cmd': 'delALL',
        'val': 'all'
    } 
    results = sharedData.addToQueue([command])
    return "Done"

# Make sure on public facing site they can only remove racers that match their owned racers
# session manager:
# keeps track of data and manages session automatically

#_______________________________ SMARL Overlay CODE _________________________________________

@app.route('/smarl_split_display', methods=['GET','POST']) # Displays Racers and the split from leader
def smarl_split_board():
    return render_template('smarl_split_display_new.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_focused_display', methods=['GET','POST']) # Displays Racers, speed, current position, and any other fun data
def smarl_focused_board():
    return render_template('smarl_focus_display_new.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_last_lap_display', methods=['GET','POST']) # Displays the last laps of all of the racers
def smarl_last_lap_board():
    return render_template('smarl_last_lap_display.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_best_lap_display', methods=['GET','POST']) # Displays the best laps of all of the racers
def smarl_best_lap_board():  
    return render_template('smarl_best_lap_display.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_qualifying_display', methods=['GET','POST']) # Displays the qualifying Split of Racers
def smarl_qualifying_board():
    return render_template('smarl_qualifying_display.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_status_display', methods=['GET','POST']) # Displays Laps left and Race Status
def smarl_status_board():
    return render_template('smarl_status_display_new.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_postqual_display', methods=['GET','POST']) # Displays Racers After their qualifying Session
def smarl_post_qualifying_board():
    return render_template('smarl_postQual_display.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_condensedqual_display', methods=['GET','POST']) # Displays Racers After their qualifying Session
def smarl_condensed_qualifying_board():
    return render_template('smarl_condensedQual_display.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)


@app.route('/smarl_starting_display', methods=['GET','POST'])  # Displays Racer Information Before  Race? before qualifyibng MIGERTED TOINTRODISPLAY
def smarl_starting_board():
    return render_template('smarl_starting_display.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_intro_display', methods=['GET','POST']) # Displays Race Information (Track, nracer...)
def smarl_intro_board():
    return render_template('smarl_intro_display.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/tarl_intro_display', methods=['GET','POST']) # Displays Race Information (Track, nracer...)
def tarl_intro_board():
    return render_template('tarl_intro_display_new.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_combo_display', methods=['GET','POST']) # Displays Both Last Lap and best lap... needed?
def smarl_combo_board():
    return render_template('smarl_combo_display_new.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_finish_display', methods=['GET','POST']) # Displays Race Results
def smarl_finish_board():
    return render_template('smarl_finish_display_new.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)


@app.route('/smarl_season_display', methods=['GET','POST']) # Displays Season Results using league
def smarl_season_board(): 
    # pull in new racer data
    sharedData.updateRacerData()
    print()
    print("\n")
    print("sending season data",sharedData._SpecificRaceData)
    return render_template('smarl_season_display.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)


@app.route('/stream_overlay', methods=['GET','POST']) # Displays Stream overlay
def stream_overlay(): 
    return render_template('stream_overlay.html')

@app.route('/api/overlay_data')
def get_overlay_data():
    data = Race_Manager.build_overlay_data() # directly builds and gets necessary data
    if not data:
        print("Error, no data found")
        return jsonify({"Error":"No data found"})
    return jsonify(data)

@app.route('/tarl_season_display', methods=['GET','POST']) # Displays Season Results using league
def tarl_season_board(): 
    # pull in new racer data
    #sharedData.updateRacerData() #cAN PULL in user_stats here
    return render_template('tarl_season_display_new.html',raceData=sharedData._SpecificRaceData,properties=sharedData._Properties)

@app.route('/smarl_get_realtime_data', methods=['GET','POST']) # Displays Race Results
def smarl_get_lapData(): #Get lap data
    print("REturning",_raceData)
    return json.dumps(_raceData)


@app.route('/smarl_map_display', methods=['GET','POST']) # Displays Race Results
def smarl_map_display(): #Get lap data
    car_data = []
    map_data = []
    if Race_Manager.TwitchRaceEnabled == False and Race_Manager.SMARL_ENABLED:
        try: # This isnt actually necessary
            response = requests.get(sharedData.get_smarl_url() + "/get_all_racers")
            response.raise_for_status()
            car_data = response.json()
        except Exception as e:
            print("Could not get all cars",e)
    else:
        pass
        #car_data[]# = Race_Manager.grabUserStats()

    try:
        file = open("../JsonData/TrackData/current_map.json")
        jsonData = json.load(file)
        print("Found Map data map data")
        map_data = jsonData
    except Exception as e:
        print("Could not get map data",e)


    return render_template('smarl_map_display.html',all_cars = car_data, map_data = map_data)

@app.route('/smarl_session_display', methods=['GET','POST']) # Displays lap history for racers
def smarl_session_display(): #Get lap data
    print("displaying session")
    return render_template('smarl_session_display.html')



@app.route('/smarl_realtime_display', methods=['GET','POST']) # Displays realtime race results
def smarl_realtime_display():
    print("displaying realtime")
    return render_template('smarl_realtime_display.html')


@app.context_processor
def test_debug():

    def console_log(input_1,  input_2 = '', input_3 = ''):
        print("logging", input_1)
        print(input_2)
        print(input_3)
        return input_1

    return dict(log=console_log)


Config_Manager = ConfigManager()
Race_Manager = RaceManager(Config_Manager,socketio)



# Can probably move these/remove these since this is passed through as "sio" now
Race_Manager.api_remove_racer = api_remove_racer
Race_Manager.api_delete_all_racers = api_delete_all_racers
Race_Manager.api_set_race = api_set_race
Race_Manager.api_reset_race = api_reset_race
def main(): 
    sharedData.init()
    # Define the file name exactly where you need it
    FILE_TO_WATCH = 'raceData.json'
    # Start the Poller thread, passing the file name and the Race_Manager instance.
    poller = RaceDataPoller(
        file_name=FILE_TO_WATCH, 
        shared_state_manager=Race_Manager
    )

    try:
        poller.start() # Start the file monitoring thread
        print(f"Monitoring thread started for {FILE_TO_WATCH}.")
    except FileNotFoundError as e:
        print(f"CRITICAL ERROR: Failed to start Poller: {e}")
    if '__main__' == __name__:
        socketio.run(app,host='0.0.0.0',port='5056', debug=True,use_reloader=False)
    
main()

# -------------------------------------------

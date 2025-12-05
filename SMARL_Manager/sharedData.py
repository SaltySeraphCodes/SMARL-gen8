import os, sys, json, time
#from winreg import *
import shutil
#from ast import parse
from urllib import response
import requests
from requests.exceptions import HTTPError
import datetime
from typing import List, Dict, Any

# RACE SPECIFIC DATA TODO: Pull from api server instead
RaceTitle = "Stream Race [Beta]"
RaceLocation = "Road Scrapton"
RaceFormat = "" # TODO: Pull booliean from ['meta_data']['qualifying'] as ' Qualifying' or ''
SeasonID = "2" # which season it is to pull sheet data from Make Dynamic?
RaceID = "8" # Make Dynamic?
LeagueTitles = ["A League", "B League","Twitch League"] #TODO: maeke array that displays title based on it
league_id = 3 # [1,2] TODO: remember this affects cars found --NOTICE if cars not showing up or being found
TwitchRace = True # Disables SMARL Stuff basically
TwitchCapacity = 10 # Number of cars allowed on entry (hard coded because yeah)
RaceFinishDelay = 60 # Seconds Before resetting race
RaceStartDelay = 740 # Seconds to wait until auto closing race entries
# Sheet name/title (when connected to gsheet)
# Grab Racer Data from Racer Data SHeet
_SpecificRaceData = {"title": RaceTitle, "location": RaceLocation, "format": RaceFormat, "season":SeasonID,"race":RaceID, "league_id":league_id,"leagueTitle":LeagueTitles[league_id-1]}
_Properties = { # various global properties
    "transition_short": 500,
    "transition_shorter": 250,
    "transition_long": 1000,
    "transition_longer": 1300
}
#// replace trrans line: find: .duration(####) replace: .duration("{{properties.transition_longer}}")
# find: yScale(Number(d['id'])) replace: yScale(i + 1) (dont forget to add i to previous function if not there)
#print("sharedData",_SpecificRaceData)
_RacerData = []
SMARL_API_URL = "http://seraphhosts.ddns.net:8080/api" # No longer works due to host migration :(
SMARL_LOCAL_URL = "http://192.168.1.250:8080/api"
SMARL_DEV_URL =  "http://192.168.1.69:8080/api"
SMARL_API_INSTRUCTIONS = "../JsonData/apiInstructs.json"
SMARL_COMMAND_QUEUE = "../JsonData/commands_to_lua.json"
SMARL_COMMAND_ACK = "../JsonData/lua_ack.json"
SMARL_TUNING_DATA = "../JsonData/tuningData.json"

IS_LOCAL = True # Remember to change this when using the dev database, Maybe automate this??
DRY_RUN = True

def get_smarl_url(): # returns smarl url based on is_local
    if IS_LOCAL: return SMARL_DEV_URL #SMARL_LOCAL_URL
    else: return SMARL_API_URL

## helpers
def formatString(strng): #formats string to have capital and replace stuf
    if strng == None:
        print('bad format string',strng)
        return ''
    output = strng.replace("_"," ")
    output = output.title()
    return output

def getTimefromTimeStr(timeStr):
    #TODO: Time string validation
    minutes = int(timeStr[0:2])
    seconds = int(timeStr[3:5])
    milliseconds = int(timeStr[6:9])
    myTime = datetime.datetime(2019,7,12,1,minutes,seconds,milliseconds)
    return myTime

def setRacerData(data):
    global _RacerData
    _RacerData = data # or append?
    print("Shared Data. setting racer Data",_RacerData)


def pull_all_racers(): # Grabs all racers and tuning data, even owner?
    all_racers = None
    jsonResponse = None
    try:
        response = requests.get(get_smarl_url() + "/get_all_racers") 
        response.raise_for_status()
        jsonResponse = response.json()
    except HTTPError as http_err:
        print(f'HTTP error occurred: {http_err}')
        return all_racers
    except Exception as err:
        print(f'GRacerdata Other error occurred: {err}')  
        return all_racers
    filtered_racers =  [d for d in jsonResponse] # here because no reason really
    return filtered_racers


def pull_racer_tuning(): # Grabs all racers and tuning data, even owner?
    all_racers = None
    jsonResponse = None
    try:
        response = requests.get(get_smarl_url() + "/get_racer_tuning") 
        response.raise_for_status()
        jsonResponse = response.json()
    except HTTPError as http_err:
        print(f'HTTP error occurred: {http_err}')
        return all_racers
    except Exception as err:
        print(f'pullTuningData Other error occurred: {err}')  
        return all_racers
    filtered_racers =  [d for d in jsonResponse] # here because no reason really
    return filtered_racers

def getRacerData(): # Only grabs racers in league
    print("Getting racer data")
    all_racers = None
    jsonResponse = None
    try:
        response = requests.get(get_smarl_url() + "/get_all_racers") # in league i
        #response = requests.get(get_smarl_url() + "/get_racers_in_season") # in league i
        #response = requests.get(get_smarl_url() + "/get_racers_in_league")
        response.raise_for_status()
        # access JSOn content
        
        jsonResponse = response.json()

        #print("got racers",jsonResponse,all_racers)
    except HTTPError as http_err:
        print(f'HTTP error occurred: {http_err}')
        return all_racers
    except Exception as err:
        print(f'GRacerdata Other error occurred: {err}')  
        return all_racers
    
    filtered_racers =  [d for d in jsonResponse if int(d['league_id']) >= 0] # all car filter
    #filtered_racers =  [d for d in jsonResponse if int(d['league_id']) == _SpecificRaceData['league_id']] # filter for league
    #TODO: Just grab all racers, doesntt need to be in league, just on map??
    #print("\n\nfiltered racers = ",len(filtered_racers),_SpecificRaceData['league_id'],"\n",filtered_racers)
    all_racers = filtered_racers
    #print("filtered racers",all_racers)
    return all_racers

def getRaceData(): #compiles season and race data
    race_data = None
    #print("Getting race data")
    try:
        response = requests.get(get_smarl_url() + "/get_current_race_data")
        response.raise_for_status()
        # access JSOn content
        jsonResponse = response.json()
        race_data = jsonResponse
    except HTTPError as http_err:
        print(f'HTTP error occurred: {http_err}')
        return race_data
    except Exception as err:
        print(f' GRD Other error occurred: {err}')        # compile owners into racers
        return race_data
    if race_data != None:
        race_data = {"title": "Race " + str(race_data['race_number']) + RaceFormat , "location": formatString(race_data['track']),
        "format": RaceFormat, "season":formatString(race_data['season_name']),"race":str(race_data['race_number']),
         "race_id": race_data['race_id'], "league_id":race_data['league_id'],"leagueTitle":LeagueTitles[league_id-1], "track_id":race_data['track_id'] } #TODO: get_leagueTitle(leagueid)
    #print("returning rd",race_data)
    return race_data


def getTrackData(track_id):
    response = requests.get(get_smarl_url() + "/get_track/"+str(track_id)) # in league i
    response.raise_for_status()
    # access JSOn content    
    jsonResponse = response.json()
    return jsonResponse

def track_record_managment(track_id,fastestLap,fastestRacer):
    #print("Checking for lap record",fastestLap,fastestRacer,track_id)
    track_data = getTrackData(track_id)
    racerID = fastestRacer['id']
    curLapTime = getTimefromTimeStr(fastestLap)

    new_record = False
    if track_data['record'] == None:
        new_record = True
    else:
        oldLapTime = getTimefromTimeStr(track_data['record'])
        if curLapTime < oldLapTime:
            print("New Record Found!",fastestLap,racerID)
            new_record = True
    
    if new_record:
        # upload directly new record data
        resultJson = {"track_id":track_id, "record_holder":racerID, 'record_time':fastestLap}
        try:
            response = requests.post(get_smarl_url() + "/update_track_record",json=resultJson )
            response.raise_for_status()
            jsonResponse = response.json()
            print("Updated Track Record",jsonResponse)
        except HTTPError as http_err:
            print(f'HTTP error occurred: {http_err}')
            return False
        except Exception as err:
            print(f'Other error occurred: {err}')        # compile owners into racers
            return False
    return new_record


def uploadQualResults(race_id,resultBody):
    resultData = None
    resultJson = {"race_id":race_id, "data":resultBody}
    print("uploading results",race_id,resultBody,resultJson)
    #pass #TODO: REMOVE THIS when ready for official race?
    if DRY_RUN == True:
        print('Not uploading because DRY RUN SET')
        return True
    try:
        response = requests.post(get_smarl_url() + "/update_race_qualifying",json=resultJson )
        response.raise_for_status()
        # access JSOn content
        jsonResponse = response.json()
        print("Uploaded Qualifying Data:")
        print(jsonResponse)
        all_racers = jsonResponse ## ??
    except HTTPError as http_err:
        print(f'HTTP error occurred: {http_err}')
        return False
    except Exception as err:
        print(f'Other error occurred: {err}')        # compile owners into racers
        return False
    return True


def uploadResults(race_id,resultBody):
    resultData = None
    resultJson = {"race_id":race_id, "data":resultBody}
    print("uploading results",race_id,resultBody,resultJson)
    #pass #TODO: REMOVE THIS when ready for official race?
    if DRY_RUN == True:
        print('Not uploading because DRY RUN SET')
        return True
    try:
        response = requests.post(get_smarl_url() + "/update_race_results",json=resultJson )
        response.raise_for_status()
        # access JSOn content
        jsonResponse = response.json()
        print("Entire JSON response")
        print(jsonResponse)
        all_racers = jsonResponse
    except HTTPError as http_err:
        print(f'HTTP error occurred: {http_err}')
        return False
    except Exception as err:
        print(f'Other error occurred: {err}')        # compile owners into racers
        return False
    return True


def updateRacerData(): # gets new pull of racer data
    global _RacerData
    _RacerData = getRacerData()
    print("Pulled new racerData",_RacerData)
    

def init():
    if TwitchRace:
        return
    global _RacerData
    global _SpecificRaceData
    _RacerData = getRacerData()
    _SpecificRaceData = getRaceData()
    print('sharedData finished init')

#init()


##_______________________ API to lua Functions __________
LAST_ACK = 0

def outputCommandQueue(commandQue):
    """
    Writes the Python list of commands directly to the file as JSON.
    This eliminates the need to double-parse in addToQueue.
    """
    with open(SMARL_COMMAND_QUEUE, 'w') as outfile:
        # Use json.dump() to write the Python object (list) directly to the file stream.
        # This is the standard and safest way to write JSON files.
        json.dump(commandQue, outfile)
        
    return True

def resetCommandsFile():
    """
    Ensures the COMMANDS_FILE exists and contains a valid empty JSON list ([]) 
    by overwriting it. This is the official initialization for this file.
    """
    try:
        # Opening in 'w' (write) mode will create the file if it doesn't exist
        # and overwrite any existing content if it does.
        with open(SMARL_COMMAND_QUEUE, 'w') as outfile:
            json.dump([], outfile)
        return True
    except Exception as e:
        print(f"FATAL ERROR: Could not initialize or reset commands file: {e}")
        return False

def initialize_ack_file():
    """Ensures the ACK_FILE exists and contains valid JSON {"status": 0}."""
    ack_data = {'status': 0}
    try:
        with open(SMARL_COMMAND_ACK, 'w') as outFile:
            json.dump(ack_data, outFile)
        return 0
    except Exception as e:
        print(f"FATAL ERROR: Could not initialize ACK file: {e}")
        return -1 # Use a unique return for initialization failure

def check_ack_file(): #Checks for ack file and inits if failure
    # --- INITIAL READ AND TEMPLATE CREATION ---
    try:
        with open(SMARL_COMMAND_ACK, 'r') as inFile:
            ack_data = json.load(inFile)
            if not ack_data.get('status',False):
                initialize_ack_file()
    except FileNotFoundError:
        print("ACK file not found. Creating template.")
        return initialize_ack_file()
    except json.JSONDecodeError:
        print("ACK file corrupted. Recreating template.")
        return initialize_ack_file()
    except Exception as e:
        print(f"Unexpected error reading ACK file: {e}. Recreating template.")
        return initialize_ack_file()
    return ack_data

def waitForAcknowledge(last_ack_value: int) -> int:
    """Waits for Lua to acknowledge the previous write by updating its status file."""
    timeout = 10 
    start_time = time.time()
    current_ack_value = -1 # Start with an invalid state

    # --- INITIAL READ AND TEMPLATE CREATION ---
    ack_data = check_ack_file()
    current_ack_value = ack_data.get('status', last_ack_value)
    
    # ------------------------------------------

    # If the file was successfully read but the status value is bad (e.g., file was '{}'),
    # the .get('status', last_ack_value) handles it, so we proceed to the loop.

    # --- POLLING LOOP ---
    while current_ack_value == last_ack_value:

        time.sleep(0.05) 
        if time.time() - start_time > timeout:
            print("ERROR: Lua acknowledgement timed out.")
            return -1 

        try:
            with open(SMARL_COMMAND_ACK, 'r') as inFile:
                ack_data = json.load(inFile)
                print('gotackdata',ack_data)
            current_ack_value = ack_data.get('status', last_ack_value)
        except:
            # If corruption happens during the wait, treat as failure
            print("ERROR: ACK file corrupted during wait loop. Aborting.")
            return -1
    return current_ack_value

def addToQueue(commands):
    global LAST_ACK
    
    # --- PHASE 1: PRE-FLIGHT CHECK & ACKNOWLEDGEMENT WAIT ---
    
    if LAST_ACK != 0:
        # If LAST_ACK is NOT 0, a previous command was sent, and we MUST wait 
        # for Lua to acknowledge it before writing the new command.
        new_ack = waitForAcknowledge(LAST_ACK)
        
        if new_ack == -1:
            return "Fail (Handshake Timeout)"

        LAST_ACK = new_ack # Update the expected ACK value

    # If LAST_ACK IS 0 (First Run): 
    # We skip the wait entirely and proceed immediately to write the first command.
    # We must assume the initial state (ACK_FILE) is 0, which initialize_ack_file() guarantees.

    
    # --- PHASE 2: COMMAND WRITE & EXPECTATION SET ---

    # 1. Initialization/Reset: Ensure the command queue file is clean ([])
    resetCommandsFile()
    
    # 2. Prepare and write the command
    current_queue = [] 
    current_queue.extend(commands)
    outputCommandQueue(current_queue) # <--- This is the trigger for LUA to act!

    # 3. Critical Step: Set the new expectation for the NEXT run.
    # We wrote the command, so we expect Lua to process it and increment the ACK by 1.
    #LAST_ACK += 1 # @gemini This seems wrong, Lua right now just sets the next ack to what this already is, maintaining the deadlock 
    
    #print(f"Command sent. Next expected ACK is {LAST_ACK}.")
    return "Success"


def update_tuning_data(): # Exports updated car and tuning data to file
    racer_data = pull_racer_tuning()
    # Filter only important info (not needed anyumore but keeping as template)
    #racer_data =  [{'racer_id': d['racer_id'],
    #                'name': d['name'],
    #                'in_season': d['racer_in_season']
    #                } for d in racer_data] # here because no reason really
    print("Updating tuning data",len(racer_data))
    with open(SMARL_TUNING_DATA, 'w') as outfile:
        jsonMessage = json.dumps(racer_data)
        outfile.write(jsonMessage)

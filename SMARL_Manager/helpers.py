import os, math
import json, sys
import time
import datetime
#import sharedData
dir_path = os.path.dirname(os.path.realpath(__file__))
json_data = os.path.join(dir_path, "JsonData")
API_FILE = os.path.join(json_data, "apiInstructs.json")

def get_time_from_seconds(total_seconds):
    """
    Converts a float representing total seconds into a string formatted as 'MM:SS.MMM'.
    This function is robust against negative or non-numeric input.
    Args:
        total_seconds (float): The total duration in seconds.
    Returns:
        str: The formatted time string (e.g., "01:47.088") or "N/A" on error.
    """
    if not isinstance(total_seconds, (int, float)) or total_seconds < 0:
        return "N/A"
    minutes = math.floor(total_seconds / 60)
    remaining_seconds = total_seconds % 60
    minutes_str = f"{int(minutes):02d}"
    seconds_str = f"{remaining_seconds:06.3f}"
    
    if seconds_str.startswith('60.'):
        minutes_str = f"{int(minutes) + 1:02d}"
        seconds_str = "00.000"

    timeStr = minutes_str + ":" + seconds_str 
    
    return timeStr

def get_seconds_from_time(time_str):
    """
    Converts a time string in the 'MM.SS.MMM' format (9 characters) 
    to a total number of seconds (float).
    
    Example: "01.47.088" -> 1 minute + 47 seconds + 0.088 seconds
    """
    if len(time_str) < 9:
        print(f"Warning: Time string is too short: {time_str}")
        return 0.0  # Return 0 or handle error as appropriate
        
    try:
        minutes_str = time_str[0:2] # MM
        seconds_str = time_str[3:5] # SS
        milis_str = time_str[6:9]   # MMM

        minutes = int(minutes_str)
        seconds = int(seconds_str)
        milis = int(milis_str)

        total_seconds = (minutes * 60) + seconds + (milis / 1000.0)
        
        return total_seconds

    except ValueError:
        print(f"Error: Non-integer found in time string '{time_str}'.")
        return 0.0

def find_racer_by_id(id,dataList): #Finds racer according to id
    if dataList == None: return None
    result = next((item for item in dataList if str(item["racer_id"]) == str(id)), None)
    return result

def find_finish_results_by_id(id,dataList): #Finds racer according to id
    result = next((item for item in dataList if str(item["id"]) == str(id)), None)
    #print(result)
    return result

def find_racer_by_pos(pos,dataList):
    result = next((item for item in dataList if str(item["pos"]) == str(pos)), None)
    return result


def findFile(filename, start_dir=".."):
    """
    Recursively iterates over directories starting from 'start_dir' 
    and returns the full absolute path of the first instance of 'filename' found.
    
    Args:
        filename (str): The name of the file to search for (e.g., 'raceData.json').
        start_dir (str): The directory to begin the recursive search from (defaults to one level up).

    Returns:
        str: The full absolute path to the file, or None if not found.
    """
    # Use os.walk to generate directory names, subdirectories, and files
    for dirname, subdirs, files in os.walk(start_dir):
        if filename in files:
            # Found the file! Construct the full path and return it immediately.
            full_path = os.path.join(dirname, filename)
            # Use os.path.abspath to ensure the path is fully resolved and usable
            return os.path.abspath(full_path)
    # If the loops complete without finding the file
    return None

def checkZeros(data):
    if data['pos'] == '0': # just a hack to prevent just starting vehicles from showing
        return True

def sortByKeys(keys,lis): #keys is a list of keys #mailny for points so reverse is true
    newList =sorted(lis, key = lambda i: (i[keys[0]], i[keys[1]], i[keys[2]], i[keys[3]], i[keys[4]]),reverse=True ) 
    return newList

def sortByKey(key,lis): #just sorts list by one key #mainly for pos so reverse is false
    newList =sorted(lis, key = lambda i: i[key] )
    return newList

def getIndexByKey(key,lis):
    #print('getting index',key,lis)
    newIndex = next((index for (index, d) in enumerate(lis) if d['ID'] == key), None)
    return newIndex
    
def getTimeFromTimeStr(timeStr):
    minutes = int(timeStr[0:2])
    seconds = int(timeStr[3:5])
    milliseconds = int(timeStr[6:9])
    myTime = datetime.datetime(2019,7,12,1,minutes,seconds,milliseconds)
    return myTime

def getFastestLap_racer(finishData):
    fastestTime = None
    fastestRacer = None
    timeStr = None
    for racer in finishData:
        ch_tStr = racer['bestLap']
        chTime = getTimeFromTimeStr(ch_tStr)
        if fastestTime == None:
            fastestTime = chTime
            fastestRacer = racer
            timeStr = ch_tStr
        elif chTime < fastestTime:
            fastestTime = chTime
            fastestRacer = racer
            timeStr = ch_tStr
    return timeStr,fastestRacer

def determineFastestLap(allRacers,racerLap): #checks what the fastest lap was
    racerTime = getTimeFromTimeStr(racerLap)
    isFastest = True
    for racer in allRacers:
        ch_tStr = racer['bestLap']
        chTime = getTimeFromTimeStr(ch_tStr)
        if chTime < racerTime:
            isFastest = False
    return isFastest
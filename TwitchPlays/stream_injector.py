import time
import sys
import os
import json
import random
from typing import Dict, Any, List

# --- IMPORTANT ---
# Assume readStream.py is in the same directory.
import readStream 
from readStream import ChatCommandProcessor, SETTINGS, checkEntered, ALL_BPS, ALL_COLORS
ALL_USERNAMES = ["ccscrapracingleague","BillyGoesRacing","JJDoneDirty","AngyViewer293","projectburnout","PippingMyPie","opensourceloser",
                 "artschoolreject","bushdidwhat","chinaownstwitch","bezosdidmushroom","engineoncrack","rocketman282","pinkiepusher",
                 "imrunningoutofnames","saltyseraoh26","scrapmannot","kanxkosmo","imurbiggestfan","codingishard"]
# --- DUMMY CHAT DATA ---
def generate_chat_item(message: str, username: str, userid: str, is_sponsor: bool = False, amount: float = 0.0) -> Dict[str, Any]:
    """
    Generates a dictionary payload that mimics the structure 
    expected by ChatCommandProcessor.parseMessage().
    """
    return {
        'message': message, 
        'author': {
            'name': username,
            'channelId': userid,
            'isChatSponsor': is_sponsor,
            'isChatModerator': False,
        },
        'amountValue': amount,
        'timestamp': time.time(),
    }

# --- NEW SIMULATION FUNCTION FOR MULTIPLE JOINS ---
def simulate_multiple_joins(processor: ChatCommandProcessor, max_racers: int):
    """Simulates multiple unique users attempting to join the race."""
    print(f"\n[TEST BULK JOIN] Simulating {max_racers} join attempts.")
    
    join_count = 0
    usernames = ALL_USERNAMES[:]
    random.shuffle(usernames)
    
    for i in range(1, max_racers + 1):
        user_name = usernames[i]
        user_id = f"UID_{user_name}"
        
        # Randomly choose body type and two colors for a unique join command
        body = random.choice(ALL_BPS)
        color1 = random.choice(ALL_COLORS)
        color2 = random.choice(ALL_COLORS)
        
        # Ensure colors are unique for better testing of the parse_join_params logic
        while color2 == color1:
             color2 = random.choice(ALL_COLORS)

        message = f"!join {body} {color1} {color2}"
        
        chat_item = generate_chat_item(
            message=message, 
            username=user_name, 
            userid=user_id,
            is_sponsor=(i % 5 == 0) # Make every 5th racer a sponsor
        )
        
        print(f"  -> Attempt {i:02d}: {user_name} sends '{message}'")
        # Injects the chat item into the processor
        processor.process_incoming_chat(chat_item) 
        
        # Small delay to simulate real chat flow
        time.sleep(0.05) 
        
        # The local list check is simplified for test mode, assuming the API call passed
        #if checkEntered(processor.joinedChatters, 'uid', user_id):
        #    join_count += 1
            
    print(f"\nBulk Join Simulation Complete. Racers currently in local list: {join_count}")
    return join_count

# --- SIMULATED CHAT SEQUENCE (Updated) ---
def run_simulation(processor: ChatCommandProcessor, total_racers_to_test: int):
    print("--- Starting Chat Command Injection Simulation ---")
    
    # 1. Setup Initial State 
    # NOTE: Relying on processor._load_current_state() from readChat for initial state
    #processor.simSettings['entries_open'] = True # Force entries open for test start
    
    # Keeping the original capacity setting from SETTINGS
    capacity = processor.SETTINGS.get('capacity', 16) 
    
    print(f"Current Entries Open: {processor.simSettings.get('entries_open', 'N/A')}")
    #print(f"Target Capacity (from SETTINGS): {capacity}")
    time.sleep(2)

    # --- Test Case 1: Bulk Join up to Capacity ---
    # We pass the capacity defined in SETTINGS for the loop range
    simulate_multiple_joins(processor, total_racers_to_test) 
    time.sleep(1)

    # --- Test Case 2: Join Rejection (Entries Closed by Capacity) ---
    #print("\n[TEST 2] User C attempts to join *after* capacity is reached.")
    #user_c_name = "RacerC-OVERCAP"
    #user_c_id = "UC017"
    #chat_c = generate_chat_item(
    #    message="!join aqua", 
    #    username=user_c_name, 
    #    userid=user_c_id
    #)
    #processor.process_incoming_chat(chat_c)
    #time.sleep(0.5)

    # Check that the number of joined chatters is exactly the capacity
    #if len(processor.joinedChatters) == capacity:
    #     print(f"Success: {user_c_name} was correctly rejected (local count: {len(processor.joinedChatters)}).")
    #else:
    #     print(f"Failed: The local list count is incorrect ({len(processor.joinedChatters)} != {capacity}).")
         
    # --- Test Cases 3 & 4 (Leave/Re-join) are intentionally commented out ---
    
    print(f"\nFinal Racers in Local List: {len(processor.joinedChatters)}")
    print("--- Simulation Complete ---")


if __name__ == '__main__':
    # --- Configuration ---
    # Note: This is now just a starting point for the capacity setting.
    # The actual capacity is read from SETTINGS in readStream.py.
    MAX_ALLOWED_RACERS = 20

    # ---------------------
    processor = ChatCommandProcessor(settings=SETTINGS)
    processor._load_current_state()


    while True:
        processor._load_current_state()


        try:
            # use real test case
            MAX_RACERS_TO_SIMULATE = random.randint(1,MAX_ALLOWED_RACERS) #Will use this to control how many users trying to join at a time

            if processor.SETTINGS['entries_open']:
                print("Attempting to join race",MAX_RACERS_TO_SIMULATE)
                # Check for command line override (e.g., python stream_injector.py 10)
                # This only updates the capacity within the SETTINGS *copy* used by the processor
                if len(sys.argv) > 1:
                    try:
                        override_count = int(sys.argv[1])
                        processor.SETTINGS['capacity'] = override_count
                        print(f"Using command line override: {override_count} racers.")
                    except ValueError:
                        print("Invalid integer provided for max racers. Using capacity from readStream.py's SETTINGS.")
                        
                # Start the simulation, using the capacity set in the processor's SETTINGS
                run_simulation(processor, MAX_RACERS_TO_SIMULATE) 
            else:
                print("Race Entries closed")
        except Exception as e:
            print(f"\nFATAL ERROR DURING INJECTION: {e}")
            # Print a traceback if possible for easier debugging
            import traceback
            traceback.print_exc()
        time.sleep(60)
import os
import pygame.mixer
import pygame.event
import random
import time
from typing import Tuple, List

# --- Pygame Initialization ---
# Setting environment variables for systems without a display/sound (like a server)
os.environ['SDL_VIDEODRIVER'] = 'dummy' 
os.environ['SDL_AUDIODRIVER'] = 'dsound'

# Initialize the mixer once at the start of your script
SONG_END_EVENT = pygame.USEREVENT + 1
pygame.mixer.init()
pygame.init()
pygame.mixer.music.set_endevent(SONG_END_EVENT)

# --- Global Music States ---
FADE_TIME = 2000 # Milliseconds
CURRENT_PLAYING_STATE = None # Tracks which state is currently active ("RACE", "PREP", etc.)
LAST_PLAYED = None # Tracks the full path of the last song played (to prevent immediate repeat)
MASTER_VOLUME = 0.1
CURRENT_PLAYING_TITLE = "Nothing Playing"
CURRENT_PLAYING_ARTIST = ""

# --- New Global State for Playlist Management ---
# MASTER_PLAYLISTS: Stores the full, never-mutated list of tracks for each state.
MASTER_PLAYLISTS = {} 
# ACTIVE_QUEUES: Stores the temporary, mutable list of tracks (songs are popped from here).
ACTIVE_QUEUES = { 
    "PREP": [],
    "START": [],
    "RACE": [],
    "FINAL": [],
    "RESET": []
}


def load_playlist_from_folder(folder_path: str) -> List[str]:
    """
    Scans a directory for all .mp3 files and returns their full paths.
    """
    playlist = []
    
    # 1. Check if folder exists before trying to list contents
    if not os.path.isdir(folder_path):
        print(f"Error: Music folder not found at '{folder_path}'. Skipping playlist load.")
        return []
        
    for filename in os.listdir(folder_path):
        # 2. Check if the file ends with .mp3 (case-insensitive)
        if filename.lower().endswith(".mp3"):
            # 3. Construct the full, correct path
            full_path = os.path.join(folder_path, filename)
            playlist.append(full_path)
            
    # NOTE: No shuffling here; shuffling happens when the queue is loaded/refilled.
    print(f"Loaded {len(playlist)} songs from: {folder_path}")
    return playlist

# Load MASTER Playlists once at startup
MASTER_PLAYLISTS["PREP"] = load_playlist_from_folder("Music/Prep")
MASTER_PLAYLISTS["START"] = load_playlist_from_folder("Music/Start")
MASTER_PLAYLISTS["RACE"] = load_playlist_from_folder("Music/Race")
MASTER_PLAYLISTS["FINAL"] = load_playlist_from_folder("Music/Final")
MASTER_PLAYLISTS["RESET"] = load_playlist_from_folder("Music/Cooldown")


def parse_track_info(track_path: str) -> Tuple[str, str]:
    """
    Parses the filename to extract the Artist and Title.
    """
    filename = os.path.basename(track_path)
    base, _ = os.path.splitext(filename)
    
    if base.startswith("ES_"):
        base = base[3:] 
    
    parts = base.split(" - ")
    
    if len(parts) >= 2:
        title = parts[0].strip()
        artist = parts[-1].strip()
    else:
        title = base.strip()
        artist = "Unknown Artist"
        
    return title, artist


def get_next_track(state_key: str) -> Tuple[str, Tuple[str, str]]:
    """
    Selects the next track from the active queue for the given state.
    Refills, shuffles, and ensures unique playback until the queue is exhausted.
    """
    global LAST_PLAYED
    
    current_queue = ACTIVE_QUEUES[state_key]
    master_list = MASTER_PLAYLISTS[state_key]

    if not master_list:
        raise IndexError(f"Master playlist for state '{state_key}' is empty.")

    # --- UNIQUE PLAYBACK LOGIC (Refill and Shuffle) ---
    if not current_queue:
        print(f"Queue for {state_key} is empty. Refilling and shuffling playlist!")
        
        # 1. Start with a fresh copy of the master list
        current_queue.extend(master_list)
        
        # 2. Shuffle for random, unique order
        random.shuffle(current_queue)
        
        # 3. Safety Check: Ensure the first song of the new queue isn't the last one played
        if current_queue and current_queue[0] == LAST_PLAYED and len(current_queue) > 1:
            # Move the first song to the end 
            song_to_move = current_queue.pop(0)
            current_queue.append(song_to_move)

    # 4. Get the next track by popping from the end of the shuffled queue
    track_path = current_queue.pop()
    
    # 5. Update the global LAST_PLAYED tracker (This is redundant due to the check on refill)
    # LAST_PLAYED = track_path
    
    return track_path, parse_track_info(track_path)


def play_dynamic_music(state_key: str):
    global CURRENT_PLAYING_STATE
    global CURRENT_PLAYING_ARTIST
    global CURRENT_PLAYING_TITLE

    # Check 1: If the state is already correct and music is playing, do nothing.
    if state_key == CURRENT_PLAYING_STATE and pygame.mixer.music.get_busy():
        return
    
    print("getting track for",state_key)
    # --- STEP 1: FADE OUT AND STOP OLD MUSIC ---
    if pygame.mixer.music.get_busy():
        pygame.mixer.music.fadeout(FADE_TIME)
        
        start_time = time.time()
        # Wait for the fadeout duration (or until the music stops)
        # We only wait for FADE_TIME + a small buffer.
        while pygame.mixer.music.get_busy() and (time.time() - start_time) < (FADE_TIME / 1000.0) + 0.1: 
            pygame.event.pump() 
            time.sleep(0.01)
        
        # Final stop just in case
        if pygame.mixer.music.get_busy():
            pygame.mixer.music.stop()
        
    # --- STEP 2: VALIDATE AND SET NEW STATE ---
    if state_key not in MASTER_PLAYLISTS:
        print(f"Error: Unknown state key '{state_key}'")
        return
        
    CURRENT_PLAYING_STATE = state_key
    
    # --- STEP 3: Load and Play the NEW track ---
    try:
        # get_next_track manages the unique playback logic internally
        track_path, (title, artist) = get_next_track(state_key)
    except IndexError as e:
        print(f"Cannot play music: {e}")
        return
    
    CURRENT_PLAYING_TITLE = title
    CURRENT_PLAYING_ARTIST = artist
    
    pygame.mixer.music.load(track_path)
    
    pygame.mixer.music.set_volume(MASTER_VOLUME) 
    # Use play(0) which means "play once". The SONG_END_EVENT will handle the loop.
    pygame.mixer.music.play(0) 


def check_music_finished_and_loop():
    """
    Checks the pygame event queue for the SONG_END_EVENT.
    If found, a new unique song is loaded and played from the current playlist.
    """
    global CURRENT_PLAYING_ARTIST
    global CURRENT_PLAYING_TITLE
    global CURRENT_PLAYING_STATE
    
    # Iterate through all pending pygame events
    for event in pygame.event.get():
        if event.type == SONG_END_EVENT:
            
            # 1. Check if we have a valid state to loop in
            if CURRENT_PLAYING_STATE is None or CURRENT_PLAYING_STATE not in MASTER_PLAYLISTS:
                print("Music ended but state is invalid or missing. Stopping loop.")
                return 

            print(f"[{CURRENT_PLAYING_STATE}] track finished. Loading next unique track...")
            
            # 2. Load and Play the NEW unique track using the correct state key
            try:
                track_path, (title, artist) = get_next_track(CURRENT_PLAYING_STATE)
            except IndexError as e:
                print(f"Cannot continue loop: {e}")
                return
            
            CURRENT_PLAYING_TITLE = title
            CURRENT_PLAYING_ARTIST = artist
            
            pygame.mixer.music.load(track_path)
            
            # 3. Resume playback
            pygame.mixer.music.set_volume(MASTER_VOLUME) 
            pygame.mixer.music.play(0) 
            
            # IMPORTANT: Return after handling the event
            return
            
"""
 Example of how to use this loop structure (Main Game Loop Mockup) ---

if __name__ == '__main__':
    # 1. Start the music in the "PREP" state
    print("\n--- Initializing Music Sequence ---")
    play_dynamic_music("PREP")
    print(f"Current Track: {CURRENT_PLAYING_TITLE} by {CURRENT_PLAYING_ARTIST}")
    
    # 2. Main loop mockup
    running = True
    state_timer = time.time()
    current_mode = "PREP"
    
    try:
        while running:
            # Check for music events every frame
            check_music_finished_and_loop()
            
            # Print status update every few seconds
            if time.time() - state_timer > 5.0:
                print(f"[{current_mode}] Playing: {CURRENT_PLAYING_TITLE} by {CURRENT_PLAYING_ARTIST}")
                state_timer = time.time()
                
            # Example state change logic (for testing transitions)
            if time.time() > 10 and current_mode == "PREP":
                current_mode = "RACE"
                play_dynamic_music("RACE")
                print(f"\n--- State Change: {current_mode} ---")
            elif time.time() > 20 and current_mode == "RACE":
                current_mode = "FINAL"
                play_dynamic_music("FINAL")
                print(f"\n--- State Change: {current_mode} ---")
            elif time.time() > 30 and current_mode == "FINAL":
                current_mode = "RESET"
                play_dynamic_music("RESET")
                print(f"\n--- State Change: {current_mode} ---")
            elif time.time() > 40 and current_mode == "RESET":
                running = False # End loop
                
            time.sleep(0.1)
            
    except KeyboardInterrupt:
        running = False
        
    finally:
        pygame.mixer.music.stop()
        pygame.quit()
        print("\nMusic playback stopped.")
"""
from pynput.keyboard import Listener  as KeyboardListener
from pynput.mouse    import Listener  as MouseListener
from pynput.keyboard import Key
import time
#very hard coded and not dynamic because yolo

_Running = True


def outputZoomIn():
    output =  "{\"zoomIn\": \"true\", \"zoomOut\": \"false\"}"
    print("Writing  "+" - " +output)
    with open('zoomControls.json', 'w') as outfile:
        outfile.write(output)

def outputZoomOut():
    output =  "{\"zoomIn\": \"false\", \"zoomOut\": \"true\"}"
    print("Writing  "+" - " +output)
    with open('zoomControls.json', 'w') as outfile:
        outfile.write(output)

def outputStopInput():
    output =  "{\"zoomIn\": \"false\", \"zoomOut\": \"false\"}"
    print("Writing  "+" - " +output)
    with open('zoomControls.json', 'w') as outfile:
        outfile.write(output)



def on_press(key):
    global _Running
    #print("got ",key)
    try:
        result = key.char
        if key.char == "=": #TODO also read mousebuttond 3 and 4
            #print("zooming in")
            outputZoomIn()

        if key.char == "-":
            #print("zoom out")
            outputZoomOut()
       
        if key.char == "/":
            output =  "{\"command\": \"cMode\", \"value\": \"0\"}" # race cam
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile:
                outfile.write(output)
        
        if key.char == "`":
            output =  "{\"command\": \"cMode\", \"value\": \"1\"}" # Drone cam
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile:
                outfile.write(output)
        
        if key.char == "\\":
            output =  "{\"command\": \"cMode\", \"value\": \"2\"}" # Free cam
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile:
                outfile.write(output)

        if key.char == ",":
            output =  "{\"command\": \"cMode\", \"value\": \"3\"}" # onboard cam
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile:
                outfile.write(output)

       
        if key.char == "~":
            output =  "{\"command\": \"exit\", \"value\": \"0\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile:
                outfile.write(output)

        if key.char == "[":
            output =  "{\"command\": \"focusCycle\", \"value\": \"-1\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile:
                outfile.write(output)
        if key.char == "]":
            output =  "{\"command\": \"focusCycle\", \"value\": \"1\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile:
                outfile.write(output)

        if key.char == ";":
            output =  "{\"command\": \"camCycle\", \"value\": \"-1\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile:
                outfile.write(output)
        if key.char == "'":
            output =  "{\"command\": \"camCycle\", \"value\": \"1\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile: # TODO: Can techincally have all this just be called to one output/writing command to save space
                outfile.write(output)

        

    except:
        #print(key)
        if key == Key.end:
            print("Exiting")
            _Running = False
            return False
        

        if key == Key.f1: # Toggle auto focus
            output =  "{\"command\": \"autoFocus\", \"value\": \"1\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile: #
                outfile.write(output)
        
        if key == Key.f2: # Toggle auto switch
            output =  "{\"command\": \"autoFocus\", \"value\": \"2\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile: #
                outfile.write(output)

        if key == Key.f3: # auto focus once
            output =  "{\"command\": \"autoSwitch\", \"value\": \"1\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile: #
                outfile.write(output)
        
        if key == Key.f4: # auto switch once
            output =  "{\"command\": \"autoSwitch\", \"value\": \"2\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile: #
                outfile.write(output)

        if key == Key.f5:
            output =  "{\"command\": \"raceMode\", \"value\": \"0\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile: #TODO: rename cmaerainput to just control input to unify terms
                outfile.write(output)

        if key == Key.f6:
            output =  "{\"command\": \"raceMode\", \"value\": \"1\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile: #TODO: rename cmaerainput to just control input to unify terms
                outfile.write(output)

        if key == Key.f7:
            output =  "{\"command\": \"raceMode\", \"value\": \"2\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile: #TODO: rename cmaerainput to just control input to unify terms
                outfile.write(output)

        if key == Key.f8:
            output =  "{\"command\": \"raceMode\", \"value\": \"3\"}"
            print("Writing  "+" - " +output)
            with open('cameraInput.json', 'w') as outfile: #TODO: rename cmaerainput to just control input to unify terms
                outfile.write(output)
        
       

        pass
   
def on_release(key):
    try:
        result = key.char
        if key.char == "=":
            outputStopInput()

        if key.char == "-":
            outputStopInput()
    except:
        pass 
    
    #if key == keyboard.Key.esc:
    #    # Stop listener
    #    return False



def on_move(x, y):
    pass
    #print('Pointer moved to {0}'.format(
    #    (x, y)))

def on_click(x, y, button, pressed):
    if pressed:
        if button == button.x1:
            outputZoomOut()
        if button == button.x2:
            outputZoomIn()
    #print('{0} at {1}'.format(
    #   'Pressed' if pressed else 'Released',
    #   (x, y)))
    if not pressed:
        if button == button.x1:
            outputStopInput()
        if button == button.x2:
            outputStopInput()
        

def on_scroll(x, y, dx, dy):
    pass
    #print('Scrolled {0} at {1}'.format(
    #    'down' if dy < 0 else 'up',
    #    (x, y)))

# Collect events until released


# Collect events until released
#Klistener = keyboard.Listener(
#        on_press=on_press,
#        on_release=on_release)

# ...or, in a non-blocking fashion:
#Mlistener = mouse.Listener(
#    on_move=on_move,
#    on_click=on_click,
#    on_scroll=on_scroll)

def main():
    global _Running
    print("Running listener")
    with MouseListener(on_click=on_click) as listener:
        with KeyboardListener(on_press=on_press) as listener:
            listener.join()
    print("Finished listener")
    #Klistener.start()
    #Mlistener.start()
    
    #while _Running:
    #    if time.time()-LastTime >= 5: # the break time,5 is second
    #        print("You need break your computer")
    #        LastTime = time.time()
    #    if _Running == False:
    #        print("Exiting")

    
main()

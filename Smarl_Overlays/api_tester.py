# test api requests without actual site
# json for sm requires double quotes so use json.dumps in post param
import requests
import json
import time
def main():
    # Test Pit stop requests\
    url = 'http://192.168.1.13:5056/api/receive_command'
    print("Running API tests")
    pit_request = {
        "cmd": "carPIT",
        "val": {
            "racer_id": 3,
            "Tire_Change": 1, 
            "Fuel_Fill" : 100
        }
       
    }
    #x = requests.post(url, json = json.dumps(pit_request))
    #print("post 1:",x)
    time.sleep(1)
    pit_request = {
        "cmd": "carPIT",
        "val": {
            "racer_id": 1,
            "Tire_Change": 1, 
            "Fuel_Fill" : 100
        }
       
    }
    x = requests.post(url, json = json.dumps(pit_request))
    #print("post2",x)

main()


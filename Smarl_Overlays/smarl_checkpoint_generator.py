import math,os, time, json

validCpActions =['1','0','-1']

def findLogFile():
    max_mtime = 0
    max_file = ""
    
    for dirname,subdirs,files in os.walk("../Logs"):
        #print(dirname,subdirs,files)
        for fname in files:
            
            full_path = os.path.join(dirname, fname)
            #print(full_path)
            mtime = os.stat(full_path).st_mtime
            if mtime > max_mtime and fname[0:4] == 'game':
                max_mtime = mtime
                max_dir = dirname
                max_file = fname
    if max_file == "":
        print("No log file found")

    return max_file
  

def readFile(logFile):
    # Set the filename and open the file
    # H:\Applications\Steam\steamapps\common\Scrap Mechanic\Logs
    filename = '../Logs/'+logFile
    print("opening",filename)
    file = open(filename,'r')

    #Find the size of the file and move to the end
    st_results = os.stat(filename)
    st_size = st_results[6]
    file.seek(st_size)
    cpList = []
    cpID = 1 # Starts on start/Finishlihne
    cpSection = 0 # 0 is right side, 1 is left
    cpDict = {}
    curDir = 0
    while 1:
        where = file.tell()
        line = file.readline()
        if not line:
            time.sleep(1)
            file.seek(where)
        else:
            if "checkpoint_data=" in line:
                startIndex = line.find("{")
                data = line[startIndex:]
                data = json.loads(data)
                locationX= data['locX'] 
                locationY= data['locY']
                if cpSection == 0:
                    cpDict = {}
                    cpDict['id'] = cpID
                    cpDict['x1'] = locationX
                    cpDict['y1'] = locationY
                    print(cpID, "Logged Section 0",cpDict)
                elif cpSection == 1:
                    cpDict['x2'] = locationX
                    cpDict['y2'] = locationY
                    print(cpID, "Logged Section 1",cpDict)
                    print()
                    cpAction = input("Insert Action: ")
                    while cpAction not in validCpActions:
                        print("invalid action")
                        cpAction = input("Insert Action: ")
                    cpDict['action'] = cpAction
                    curDir = (curDir + int(cpAction)) % 4
                    cpDict['dir'] = curDir
                    nextCp = input("next cpID: ")
                    cpDict['nxt'] = nextCp
                    cpList.append(cpDict)
                    if nextCp == '1':
                        print("Finished generating?\n",cpList)
                        input()
                        outputCheckPointData(cpList)
                        break
                    cpID = nextCp
                    print("Finished CP",cpDict)
                    print()
                 
                    print("Checkpoint List:",cpID,cpList)
                    print()
                    print()

                cpSection = (cpSection +1) %2
                print(cpID,"-----",cpSection)

def outputCheckPointData(cpList):
    print("outputting\n")
    for checkPoint in cpList:
        outputStr = "{['id'] = "+str(int(checkPoint['id']))+", ['x1'] = "+str(float(checkPoint['x1']))+", ['y1'] = "+str(float(checkPoint['y1']))+", ['x2'] = "+str(float(checkPoint['x2']))+", ['y2'] = "+str(float(checkPoint['y2']))+", ['action'] = "+str(int(checkPoint['action']))+",  ['dir'] = "+str(int(checkPoint['dir']))+", ['nxt'] = "+str(int(checkPoint['nxt']))+"},"
        print(outputStr)
    print("Done")


def main():
    logFile = findLogFile()
    print("FoundLogfile ",logFile)
    readFile(logFile)
   
main()


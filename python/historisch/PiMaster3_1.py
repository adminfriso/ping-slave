from multiprocessing import Process, Pipe
try:
    import contextlib
    with contextlib.redirect_stdout(None): #disabled de irritante welkom tekst van pygame
        from pygame import mixer
except:
    from pygame import mixer
mixer.init()
#from soundSlave3_1 import player
from pixelSlave3_1 import pixels
from probeSlave3_1 import probe
from systemSlave3_1 import system
#from prompt_toolkit import prompt
import time

if __name__ == '__main__':
    while 1:
        parent_conn,child_conn = Pipe()
        try:
            com = raw_input("s/i,file,volume>")
        except Exception as e:
            print(e)
            #print('reached')
            #com="s,0,/home/pi/ch0.wav,0.08,1"
        try: ## stop process
            if com=="SS":
                p.terminate()
                print("process terminated")
        except:
            print("-")
        try:
            com = com.split(",")
#            #print(com[0])
#            tijd = com[1]
#            if tijd=="":
#                tijd=("+0")
#            if tijd[0]=="+": #+10 betekend over 10 sec, 0 is gelijk
#                tijd=float(tijd[1:])+time.time()
                #time=even
#            if len(com)>2:
#                loop=int(com[4])
            if com[0][0]=="s":
                soundFile=com[1]
#                if soundFile=="":
#                    soundFile="ch0.wav"
#                if com[3]=="":
#                    volume=0.5
#                else:
                sound = mixer.Sound(soundFile)
                volume=float(com[2])
                sound.set_volume(volume) 
                mixer.Sound.play(sound)
                p=""
                #p = Process(target=player, args=(child_conn,tijd, soundFile, volume, loop-1))
            elif com[0]=="i":
                imgFile=com[1]
#                if imgFile=="":
#                    soundFile=beeld.jpg
                duration=float(com[2])
#                if com[3]=="":
#                    duration=3
#                else:
                #duration=float(com[3])
                p = Process(target=pixels, args=(child_conn, imgFile, duration))
            elif com[0]=="p":
                tijd=com[1]
                p = Process(target=probe, args=(child_conn,tijd))
            elif com[0]=="com":
                command=com[1]
                p = Process(target=system, args=(child_conn,command))
            else:
                print("no good")
            com=""
            if p!="" : p.start()
        except Exception as e:
            print(e)
            #print(com)
            #print("not done")

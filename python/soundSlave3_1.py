from multiprocessing import Process,Pipe
import time



def player(child_conn,tijd,soundFile, volume,loop):
    
    #voice = mixer.Channel(0)
    sound = mixer.Sound(soundFile)
    sound.set_volume(volume)
    tijd=float(tijd)
    while (time.time()<tijd):
        a=1
    mixer.Sound.play(sound, loops = loop)
    while loop==-1: # als geluid loopt werkt de get_busy niet, wel bij herhalingen
        a=1
    while mixer.get_busy():
        a=1
    delay(0.3)
    #mixer.quit()
#---------

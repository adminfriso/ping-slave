from multiprocessing import Process,Pipe
import time
try:
    import contextlib
    with contextlib.redirect_stdout(None): #disabled de irritante welkom tekst van pygame
        from pygame import mixer
except:
    from pygame import mixer


def player(child_conn,tijd,soundFile, volume,loop):
    mixer.init()
    voice = mixer.Channel(0)
    sound = mixer.Sound(soundFile)
    voice.set_volume(volume)
    tijd=float(tijd)
    while (time.time()<tijd):
        a=1
    voice.play(sound, loops = loop)
    while loop==-1: # als geluid loopt werkt de get_busy niet, wel bij herhalingen
        a=1
    while voice.get_busy():
        a=1
    mixer.quit()
#---------

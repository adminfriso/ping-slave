#commands:
#E,whiteoff
#E,whiteon
#E,whitepulseoff
#E,whitepulseon
#E,statusoff
#E,statuson
#s,path,volume(0-1),wait(epoch-millis)
#i,path,duration(secs,0-...),wait(epoch-millis)

import subprocess
import threading
import Queue
import time
import sched
from gpiozero import PWMLED
from gpiozero import LoadAverage, PingServer

#sound config
try:
    import contextlib
    with contextlib.redirect_stdout(None): #disabled de irritante welkom tekst van pygame
        from pygame import mixer
except:
    from pygame import mixer
mixer.init()
## import PIL
from PIL import Image
from PIL import ImageChops
# white LEDS
led = PWMLED(20)
led.value=0
# addressable LEDS
from neopixel import *
LED_COUNT      = 200     # Number of LED pixels.
LED_PIN        = 13      # GPIO pin connected to the pixels (18 uses PWM!).
LED_FREQ_HZ    = 800000  # LED signal frequency in hertz (usually 800khz)
LED_DMA        = 10      # DMA channel to use for generating signal (try 10)
LED_BRIGHTNESS = 255     # Set to 0 for darkest and 255 for brightest
LED_INVERT     = False   # True to invert the signal (when using NPN transistor level shift)
LED_CHANNEL    = 1       # set to '1' for GPIOs 13, 19, 41, 45 or 53
strip = Adafruit_NeoPixel(LED_COUNT, LED_PIN, LED_FREQ_HZ, LED_DMA, LED_INVERT, LED_BRIGHTNESS, LED_CHANNEL)
strip.begin()
gamma8 = [ 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,4,4,4,4,4,5,5,5,
    5,6,6,6,6,7,7,7,7,8,8,8,9,9,9, 10, 10, 10, 11, 11, 11, 12, 12, 13, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21,
           21, 22, 22, 23, 24, 24, 25, 25, 26, 27, 27, 28, 29, 29, 30, 31, 32, 32, 33, 34, 35, 35, 36,
   37, 38, 39, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 50, 51, 52, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 66, 67, 68,
   69, 70, 72, 73, 74, 75, 77, 78, 79, 81, 82, 83, 85, 86, 87, 89, 90, 92, 93, 95, 96, 98, 99,101,102,104,105,107,109,110,112,114,
  115,117,119,120,122,124,126,127,129,131,133,135,137,138,140,142, 144,146,148,150,152,154,156,158,160,162,164,167,169,171,173,175,
  177,180,182,184,186,189,191,193,196,198,200,203,205,208,210,213, 215,218,220,223,225,228,231,233,236,239,241,244,247,249,252,255 ]
strip = Adafruit_NeoPixel(LED_COUNT, LED_PIN, LED_FREQ_HZ, LED_DMA, LED_INVERT, LED_BRIGHTNESS, LED_CHANNEL)
strip.begin()
#init global variables
frame=0;starttijd=0;Beeld=None;led0=Color(0,0,0);led1=Color(0,0,0)
scheduler = sched.scheduler(time.time, time.sleep)
#init start
fps=25
whiteleds=False
whitepulse=True
status=True

# thread safe
lightQueue = Queue.Queue()
soundQueue = Queue.Queue()

def SetStatus(name):
    if Beeld==None and status==True :
        #processor load
        cpu = int(LoadAverage().value*250)
        if (cpu>255): cpu=255
        if (cpu<0):cpu=0
        cpu = gamma8[cpu]
        led0 = Color(0,cpu,0) # groen is 100%
        #netwerk verbinding
        check = PingServer("192.168.8.1")
        if (check.value==True):
            b=120
        else:
            b=10
        check = PingServer("8.8.8.8")
        if (check.value==True):
            g=120
        else:
            g=10
        check = PingServer("192.168.8.50")
        if (check.value==True):
            r=120
        else:
            r=10
        led1 = Color(b,g,r)
            
        #gitstatus up to date met head? ->     moet nog
        strip.setPixelColor(0, led0)
        strip.setPixelColor(1, led1)
        strip.show()
    e1 = scheduler.enter(1, 1, SetStatus, ('check',))

def imgMerge (orImg,newImg,frame):
    widthNewImg,heigthNewImg = newImg.size
    widthorImg,heigthorImg = orImg.size
    if (widthorImg<frame+widthNewImg):
        newWidth=frame+widthNewImg
    else:
        newWidth=widthorImg
    big1 = Image.new('RGB', (newWidth, 200),0)
    big1.paste(orImg,(0,0)) #big1 is nu orImg met zwart er naast
    big2 = Image.new('RGB', (newWidth, 200),0)
    big2.paste(newImg,(frame,0))
    finalImg = ImageChops.lighter(big1, big2)
    return finalImg

def showLeds (im,frame):
    #witte leds
    if whiteleds:        
        b,g,r = im.getpixel((frame, 0))
        r = gamma8[r]
        L = r*0.39
        led.value=L/255
    #addressables
    for y in range (0,im.height):
        b,g,r = im.getpixel((frame, y))
        r=gamma8[r]
        g=gamma8[g]
        b=gamma8[b]
        strip.setPixelColor(y, Color(b,g,r))
    if status:
        strip.setPixelColor(0, led0)
        strip.setPixelColor(1, led1)
    strip.show()

class LightSlave(threading.Thread):
    def init(self):
        threading.Thread.init(self)
        self.command = None

    def run(self):
        starttijd=0
        Beeld=None
        frame=0
        while True:
            #check for new command
            if lightQueue.qsize() > 0:
                self.command = lightQueue.get()
                comWords = self.command.split(",")
                imgFile=comWords[1]
                duration=float(comWords[2])
                im = Image.open(imgFile)
                im = im.convert("RGB") 
                im = im.resize((int(duration*fps),200),5) #PI2.Image.LANCZOS
                if (Beeld!=None): 
                    Beeld = imgMerge(Beeld,im,frame)
                else:
                    Beeld=im
                    frame=0
            else:
                strip.show()
                time.sleep(0.01)
            #check of tijd verloopt voor nieuwe frame
            elapsed=(time.time()*1000)-starttijd        
            if (Beeld!=None):
                if (elapsed>(1000/fps)):
                    starttijd=time.time()*1000;elapsed=0
                    #show leds
                    breedte, hoogte = Beeld.size
                    if (frame<breedte):
                        showLeds(Beeld,frame)
                    else:
                    #aan einde van Image alles reset
                        Beeld=None
                        #clear all LEDs
                        for y in range (0,200):
                            strip.setPixelColor(y, Color(0,0,0))
                        if status:
                            strip.setPixelColor(0, led0)
                            strip.setPixelColor(1, led1)
                        strip.show()    
                        led.value=0
                    frame+=1
            else:
                pass


class SoundSlave(threading.Thread):
    def __init__(self):
        threading.Thread.__init__(self)
        self.command = None

    def run(self):
        while True:
            if soundQueue.qsize() > 0:
                self.command = soundQueue.get()
                comWords = self.command.split(",")
                soundFile=comWords[1]
                sound = mixer.Sound(soundFile)
                volume=float(comWords[2])
                sound.set_volume(volume) 
                mixer.Sound.play(sound)
                if whitepulse==True:
                        led.blink(0.1, 0, 1, 0.5, 1, True) #ontime, offtime, fadeintime, fade out time, n-times, in background
            else:
                strip.show()
                time.sleep(0.01)
                
class WaitSlave(threading.Thread):
    def __init__(self, wait, com):
        threading.Thread.__init__(self)
        self.wait = wait
        self.com = com
        self.command = None

    def run(self):
        comWords = self.com.split(",")
        #time
        tijd=nt(self.wait)
        print(self.com + " waiting:"+tijd-(time.time()*1000))
        try:
            while ((time.time()*1000)<tijd):
                pass
            print("WaitSlave waited, but now running:" + self.com)
            try:
                #sound
                if comWords[0]=="s":
                    soundQueue.put(self.com)
                #image
                elif comWords[0]=="i":
                    lightQueue.put(self.com)
                else:
                    print("python, not processable:" + self.com)
            except Exception as e:
                print(e)
        except Exception as e:
            print(e)

                
                
def start():
    c = LightSlave()
    s = SoundSlave()
    
    threads = [c, s]

    for thread in threads:
        thread.setDaemon(True)
        thread.start()

    print ("Going on!")
    
def updatePython():
    print("updating python...")
    os.system("git fetch")
    strip.fill((100,0,0))
    strip.show()
    os.system("git add .")
    strip.fill((0,100,0))
    strip.show()
    os.system("git reset HEAD --hard")
    strip.fill((0,0,100))
    strip.show()
    os.system("git pull")
    strip.fill((100,100,100))
    strip.show()
    os.system("npm install")
    led.blink(0.1, 0, 1, 0.5, 1, True)
    os.system("sudo reboot")

def updateApt():
    print("updating apt...")
    os.system("apt update && apt upgrade -y")
    strip.fill((0,100,0))
    strip.show()
    os.system("sudo reboot")
    led.blink(0.1, 0, 1, 0.5, 1, True)

if __name__ == '__main__':
    start()
    #set scheduler for statuscheck
    e1 = scheduler.enter(10, 1, SetStatus, ('check',))
    threading.Thread(target=scheduler.run).start()
    while 1:
        try:
            com = raw_input("s/i,file,volume(,time)>")
            comWords = com.split(",")
        except Exception as e:
            print(e)
        try:
            #wait
            if len(comWords)>3: #dan is er time ingegeven
                E = WaitSlave(comWords[3],com)
                E.setDaemon(True)
                E.start()
            #check for Effect commands
            elif comWords[0]=="E":
                if com=="E,whiteoff":
                    whiteleds=False
                elif com=="E,whiteon":
                    whiteleds=True
                elif com=="E,whitepulseoff":
                    whitepulse=False
                elif com=="E,whitepulseon":
                    whitepulse=True
                elif com=="E,statusoff":
                    status=False
                elif com=="E,statuson":
                    status=True
            #sound
            elif comWords[0]=="s" and len(comWords)>2:
                soundQueue.put(com)
            #image
            elif comWords[0]=="i" and len(comWords)>2:
                lightQueue.put(com)
            #update
            elif comWords[0]=="u":
                if com=="update python":
                    updatePython()
                elif com=="update apt":
                    updateApt()
            else:
                print("python, not processable:" + com)
        except Exception as e:
            print(e)
            





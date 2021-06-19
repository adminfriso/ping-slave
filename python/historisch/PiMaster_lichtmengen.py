import threading
import Queue
import time
#sound config
try:
    import contextlib
    with contextlib.redirect_stdout(None): #disabled de irritante welkom tekst van pygame
        from pygame import mixer
except:
    from pygame import mixer
mixer.init()
# LED & LED strip configuration:
from neopixel import *
from PIL import Image
from PIL import ImageChops
import RPi.GPIO as GPIO
GPIO.setwarnings(False)
GPIO.setmode(GPIO.BCM)
GPIO.setup(20,GPIO.OUT)
pi_pwm = GPIO.PWM(20,500)
pi_pwm.start(0)
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
pi_pwm.start(0)
#init global variables
fps=60;frame=0;starttijd=0

# thread safe
lightQueue = Queue.Queue()
soundQueue = Queue.Queue()
#waitQueue = queue.Queue()

def imgMerge (orImg,newImg,frame):
    widthNewImg,heigthNewImg = newImg.size
    big1 = Image.new('RGB', (frame+widthNewImg, 200),0)
    big1.paste(orImg,(0,0)) #big1 is nu orImg met zwart er naast
    big2 = Image.new('RGB', (frame+widthNewImg, 200),0)
    big2.paste(newImg,(frame,0))
    finalImg = ImageChops.lighter(big1, big2)
    return finalImg

def showLeds (im,frame):
    #witte leds
    b,g,r = im.getpixel((frame, 0))
    r = (b+g+r)/3
    r = gamma8[r]
    L = r*0.39
    pi_pwm.ChangeDutyCycle(L)
    #addressables
    for y in range (1,im.height):
        b,g,r = im.getpixel((frame, y))
        r=gamma8[r]
        g=gamma8[g]
        b=gamma8[b]
        strip.setPixelColor(y, Color(r,g,b))
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
                im = im.resize((int(duration*fps),200),5) #PIL.Image.LANCZOS
                if (Beeld!=None): 
                    Beeld = imgMerge(Beeld,im,frame)
                else:
                    Beeld=im
                    frame=0
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
                        for y in range (1,200):
                            strip.setPixelColor(y, Color(0,0,0))
                        strip.show()    
                        pi_pwm.ChangeDutyCycle(0)
                    frame+=1

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
                #print("command->"+soundFile)
                sound = mixer.Sound(soundFile)
                volume=float(comWords[2])
                sound.set_volume(volume) 
                mixer.Sound.play(sound)
                
#class WaitSlave(threading.Thread):
#    def __init__(self):
#        threading.Thread.__init__(self)
#        self.command = None
#
#    def run(self):
#        
#        if waitQueue.qsize() > 0:
#            self.command = waitQueue.get()
#            comWords = self.command.split(",")
#            #time
#            tijd=comWords[3]
#            try:
#                while ((time.time()*1000)<tijd):
#                    pass
#                print("python waited, but now running:" + self.command)
#                try:
#                    #sound
#                    if comWords[0]=="s":
#                        soundQueue.put(self.command)
#                    #image
#                    elif comWords[0]=="i":
#                        lightQueue.put(self.command)
#                    else:
#                        print("python, not processable:" + self.command)
#                except Exception as e:
#                    print(e)
#            except Exception as e:
#                print(e)

                
                
def start():
    c = LightSlave()
    s = SoundSlave()
#    w = WaitSlave()
    
    threads = [c, s]#, w]

    for thread in threads:
        thread.setDaemon(True)
        thread.start()

    print ("Going on!")


if __name__ == '__main__':
    start()

    while 1:
        try:
            #comList.append(raw_input("s/i,file,volume(,time)>"))
            com = raw_input("s/i,file,volume(,time)>")
            comWords = com.split(",")
        except Exception as e:
            print(e)
        try:
            #wait
            if len(comWords)>3: #dan is er time ingegeven
                print("time="+comWords[3])
                #waitQueue.put(com)
            #sound
            elif comWords[0]=="s" and len(comWords)>2:
                soundQueue.put(com)
            #image
            elif comWords[0]=="i" and len(comWords)>2:
                lightQueue.put(com)
            else:
                print("python, not processable:" + com)
        except Exception as e:
            print(e)
            

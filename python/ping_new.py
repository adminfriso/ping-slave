# commands:
# s(ound),path,volume(0-1),wait(epoch-millis)
# i(mage),path,duration(secs,0-...),wait(epoch-millis) of repeatTrue/repeatFalse
# w(ait),file,volume,tijd(epoch-millis),up(milliseconds),stay(milliseconds),down(milliseconds)
# e(ffect),whiteoff
# e(ffect),whiteon
# e(ffect),whitepulseoff
# e(ffect),whitepulseon
# e(ffect),statusoff
# e(ffect),statuson
# p(robe),time(secs)
# h(eat),0..1
# c(olor),0..1,0..1,0..1

# Color=(b,g,r)

import subprocess
import threading
import Queue
import time
import sched
import os

from gpiozero import PWMLED
from gpiozero import LoadAverage, PingServer

# sound config
try:
    import contextlib
    with contextlib.redirect_stdout(None):  # disabled de irritante welkom tekst van pygame
        from pygame import mixer
except:
    from pygame import mixer
mixer.init()
mixer.set_num_channels(50)  # default is 8
from PIL import Image
from PIL import ImageChops


# white LEDS
led = PWMLED(20)
led.value = 0   #0..1

# heat
hotRes = PWMLED(16)
hotRes.value = 0    #0..1

# addressable LEDS
from neopixel import *
LED_COUNT = 200  # Number of LED pixels.
LED_PIN = 13  # GPIO pin connected to the pixels (18 uses PWM!).
LED_FREQ_HZ = 800000  # LED signal frequency in hertz (usually 800khz)
LED_DMA = 10  # DMA channel to use for generating signal (try 10)
LED_BRIGHTNESS = 255  # Set to 0 for darkest and 255 for brightest
LED_INVERT = False  # True to invert the signal (when using NPN transistor level shift)
LED_CHANNEL = 1  # set to '1' for GPIOs 13, 19, 41, 45 or 53
strip = Adafruit_NeoPixel(LED_COUNT, LED_PIN, LED_FREQ_HZ, LED_DMA, LED_INVERT, LED_BRIGHTNESS, LED_CHANNEL)
strip.begin()
# init global variables
gamma8 = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1,
          1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8,
          8, 8, 9, 9, 9, 10, 10, 10, 11, 11, 11, 12, 12, 13, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20,
          20, 21, 21, 22, 22, 23, 24, 24, 25, 25, 26, 27, 27, 28, 29, 29, 30, 31, 32, 32, 33, 34, 35, 35, 36, 37, 38,
          39, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 50, 51, 52, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64,
          66, 67, 68, 69, 70, 72, 73, 74, 75, 77, 78, 79, 81, 82, 83, 85, 86, 87, 89, 90, 92, 93, 95, 96, 98, 99, 101,
          102, 104,  105, 107, 109, 110, 112, 114, 115, 117, 119, 120, 122, 124, 126, 127, 129, 131, 133, 135, 137, 138,
          140, 142,  144, 146, 148, 150, 152, 154, 156, 158, 160, 162, 164, 167, 169, 171, 173, 175, 177, 180, 182, 184,
          186, 189,  191, 193, 196, 198, 200, 203, 205, 208, 210, 213, 215, 218, 220, 223, 225, 228, 231, 233, 236, 239,
          241, 244,  247, 249, 252, 255}
frame = 0
starttijd = 0
Beeld = None
scheduler = sched.scheduler(time.time, time.sleep)
# init start
fps = 25.0
whiteleds = False
whitepulse = True
status = True
fadeout = True
fadein = False
repeat = False
repeatFile = ""
repeatDuration = 0
repeatFlip = False
timeRatio = 0.68
#led0 = Color(0, 0, 0)
#led1 = Color(0, 0, 0)
#led2 = Color(255, 0, 255)  # version led#3
paars = Color(255, 0, 255)
Xr = 1
Xg = 1
Xb = 1

# thread safe
lightQueue = Queue.Queue()
soundQueue = Queue.Queue()

def SetStatus(check):
   if status is True:
#        # processor load
#        cpu = int(LoadAverage().value * 250)
#        if cpu > 255: cpu = 255
#        if cpu < 0: cpu = 0
#         cpu = gamma8[cpu]
#        led0 = Color(0, cpu, 255 - cpu)  # groen is 100%
#        # netwerk verbinding
#        check = PingServer("192.168.8.1")
#        if check.value is True:
#            b = 120
#        else:
#            b = 10
#        check = PingServer("8.8.8.8")
#        if check.value is True:
#            g = 120
#        else:
#            g = 10
#        check = PingServer("192.168.8.50")
#        if check.value is True:
#            r = 120
#        else:
#            r = 10
#        led1 = Color(r, g, b)

       SetStatusLeds()

   e1 = scheduler.enter(1, 1, SetStatus, ('check',))


def SetStatusLeds():
    #strip.setPixelColor(3, led0)
    #strip.setPixelColor(4, led1)
    strip.setPixelColor(5, paars)
    strip.setPixelColor(13, paars)
    #strip.setPixelColor(14, led1)
    #strip.setPixelColor(15, led0)

def imgMerge(orImg, newImg, frame):
    widthNewImg, heigthNewImg = newImg.size
    widthorImg, heigthorImg = orImg.size
    if widthorImg < (frame + widthNewImg):
        newWidth = frame + widthNewImg
    else:
        newWidth = widthorImg
    big1 = Image.new('RGB', (newWidth, 200), 0)
    big1.paste(orImg, (0, 0))  # big1 is nu orImg met zwart er naast
    big2 = Image.new('RGB', (newWidth, 200), 0)
    big2.paste(newImg, (frame, 0))
    finalImg = ImageChops.lighter(big1, big2)
    return finalImg


def Blackleds():
    for y in range(0, LED_COUNT):
        strip.setPixelColor(y, Color(0, 0, 0))
    if status:
        SetStatusLeds()
    strip.show()

def showLeds(im, frame):
    # witte leds
    if whiteleds is True:
        r, g, b = im.getpixel((frame, 0))
        r = gamma8[r]
        L = r * 0.39
        led.value = L / 255.0 # value is 0..1
    # addressables
    widthorim, heigthorim = im.size
    # print(widthorim)
    lastPart = (3.0 / 4.0) * float(widthorim)
    firstPart = (1.0 / 4.0) * float(widthorim)
    for y in range(0, heigthorim):
        r, g, b = im.getpixel((frame, y))
        # fadeIN
        if fadein is True and frame < firstPart:
            ratio = float(frame) / float(firstPart)
            r = ratio * float(r)
            g = ratio * float(g)
            b = ratio * float(b)
        # fadeOUT
        if fadeout is True and frame > lastPart:
            ratio = float(widthorim - frame) / float(widthorim - lastPart)
            # print(ratio)
            r = Xr * ratio * float(r)
            g = Xg * ratio * float(g)
            b = Xb* ratio * float(b)
        r = gamma8[int(r)]
        g = gamma8[int(g)]
        b = gamma8[int(b)]
        strip.setPixelColor(y, Color(b, g, r))
    if status:
        SetStatusLeds()
    strip.show()


class LightSlave(threading.Thread):
    def init(self):
        threading.Thread.init(self)
        self.command = None

    def run(self):
        starttijd = 0
        Beeld = None
        frame = 0
        while True:
            # check for new command
            if lightQueue.qsize() > 0:
                self.command = lightQueue.get()
                comWords = self.command.split(",")
                imgFile = comWords[1]
                duration = float(comWords[2])
                try:
                    im = Image.open(imgFile)
                    im = im.convert("RGB")
                    im = im.resize((int(duration * fps), 200), 5)  # PI2.Image.LANCZOS
                except Exception as e:
                    print(e)
                    continue
                # beeld
                if (Beeld != None):
                    Beeld = imgMerge(Beeld, im, frame)
                else:
                    Beeld = im
                    frame = 0
            else:
                # strip.show()
                time.sleep(0.001)
            # check of tijd verloopt voor nieuwe frame
            elapsed = (time.time() * 1000) - starttijd
            if Beeld is not None:
                if elapsed > (timeRatio * (1000 / fps)):
                    starttijd = time.time() * 1000
                    elapsed = 0
                    # show leds
                    breedte, hoogte = Beeld.size
                    if frame < breedte:
                        showLeds(Beeld, frame)
                    else:
                        Blackleds()
                        frame = 0
                        Beeld = None
                    frame += 1
                else:
                    time.sleep(0.001)
            else:
                time.sleep(0.001)


class SoundSlave(threading.Thread):
    def __init__(self):
        threading.Thread.__init__(self)
        self.command = None

    def run(self):
        while True:
            if soundQueue.qsize() > 0:
                self.command = soundQueue.get()
                comWords = self.command.split(",")
                soundFile = comWords[1]
                sound = mixer.Sound(soundFile)
                volume = float(comWords[2])
                sound.set_volume(volume)
                mixer.Sound.play(sound)
                if whitepulse is True:
                    led.blink(0, 0, 0.1, 0.3, 1,
                              True)  # ontime, offtime, fadeintime, fade out time, n-times, in background
            else:
                strip.show()
                time.sleep(0.01)


class WaveSlave(threading.Thread):
    def __init__(self, file, volume, tijd, up, stay, down):
        threading.Thread.__init__(self)
        self.file = file
        self.volume = float(volume)
        self.tijd = int(tijd)
        self.up = float(up) / 1000
        self.stay = float(stay) / 1000
        self.down = float(down) / 1000
        self.command = None

    def run(self):
        sound = mixer.Sound(self.file)
        sound.set_volume(0.001)
        mixer.Sound.play(sound)
        while (int(time.time() * 1000)) < self.tijd:
            time.sleep(0.001)
        if whitepulse is True:
            led.blink(self.stay, 0, self.up, self.down, 1,
                      True)  # ontime, offtime, fadeintime, fade out time, n-times, in background
        for i in range(0, 100):
            sound.set_volume((float(i) / 100) * float(self.volume))
            time.sleep(self.up / 100)
        time.sleep(self.stay)
        for i in range(0, 100):
            j = 100 - i
            sound.set_volume((float(j) / 100) * float(self.volume))
            time.sleep(self.down / 100)
        sound.set_volume(0)


class WaitSlave(threading.Thread):
    def __init__(self, wait, com):
        threading.Thread.__init__(self)
        self.wait = wait
        self.com = com
        self.command = None

    def run(self):
        comWords = self.com.split(",")
        # time
        tijd = int(self.wait)
        try:
            while (int(time.time() * 1000)) < tijd:
                time.sleep(0.001)
            try:
                # sound
                if comWords[0] == "s":
                    soundQueue.put(self.com)
                # image
                elif comWords[0] == "i":
                    lightQueue.put(self.com)
                else:
                    print("python, not processable:" + self.com)
            except Exception as e:
                print(e)
        except Exception as e:
            print(e)


class ProbeSlave(threading.Thread):
    def __init__(self, time):
        threading.Thread.__init__(self)
        self.time = time
        self.command = None

    def run(self):
        os.system('sudo ifconfig wlan0 promisc')
        os.system('sudo ifconfig wlan0 down')
        os.system('sudo iwconfig wlan0 mode monitor')
        os.system('sudo ifconfig wlan0 up')
        if int(time) > 0:
            os.system(
                "sudo timeout " + time + " tcpdump -C 10 -i wlan0 -w /home/pi/probedump" + time.time + ".pcap -tttt -e -s 256 type mgt subtype probe-req")
        else:
            os.system(
                "tcpdump -C 10 -i wlan0 -w /home/pi/probedump" + time.time + ".pcap -tttt -e -s 256 type mgt subtype probe-req")


c = LightSlave()
s = SoundSlave()
threads = [c, s]


def start():
    for thread in threads:
        thread.setDaemon(True)
        thread.start()
    print("Going on!")


if __name__ == '__main__':
    start()
    # set scheduler for statuscheck
    e1 = scheduler.enter(10, 1, SetStatus, ('check',))
    threading.Thread(target=scheduler.run).start()
    while 1:
        try:
            com = raw_input("s/i,file,volume(,time)>")
            comWords = com.split(",")
        except Exception as e:
            print(e)
        try:
            # wait
            if comWords[0] == "w":
                G = WaveSlave(comWords[1], comWords[2], comWords[3], comWords[4], comWords[5], comWords[6])
                G.setDaemon(True)
                G.start()
            elif (comWords[0] == "s" or comWords[0] == "i") and len(comWords) > 3:  # dan is er time ingegeven
                E = WaitSlave(comWords[3], com)
                E.setDaemon(True)
                E.start()
            # sound
            elif comWords[0] == "s" and len(comWords) > 2:
                soundQueue.put(com)
            # image
            elif comWords[0] == "i" and len(comWords) > 2:
                lightQueue.put(com)
            elif comWords[0] == "p":
                F = ProbeSlave(comWords[1])
                F.setDaemon(True)
                F.start()
            elif comWords[0] == "h":
                hotRes.value = float(comWords[1])
            elif comWords[0] == "c":
                Xr = float(comWords[1])
                Xg = float(comWords[2])
                Xb = float(comWords[3])
            # check for Effect commands
            elif comWords[0] == "e":
                if com == "e,whiteoff":
                    whiteleds = False
                elif com == "e,whiteon":
                    whiteleds = True
                elif com == "e,whitepulseoff":
                    whitepulse = False
                elif com == "e,whitepulseon":
                    whitepulse = True
                elif com == "e,statusoff":
                    status = False
                elif com == "e,statuson":
                    status = True
                    e1 = scheduler.enter(1, 1, SetStatus, ('check',))
                elif com == "e,fadeouton":
                    fadeout = True
                elif com == "e,fadeoutoff":
                    fadeout = False
                elif com == "e,fadeinon":
                    fadein = True
                elif com == "e,fadeinoff":
                    fadein = False

            else:
                print("python, not processable:" + com)
        except Exception as e:
            print(e)

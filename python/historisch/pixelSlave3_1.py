from multiprocessing import Process,Pipe
import time
from neopixel import *
from PIL import Image
import datetime
import RPi.GPIO as GPIO
GPIO.setwarnings(False)
GPIO.setmode(GPIO.BCM)
GPIO.setup(20,GPIO.OUT)

# LED strip configuration:
LED_COUNT      = 200      # Number of LED pixels.
LED_PIN        = 13      # GPIO pin connected to the pixels (18 uses PWM!).
LED_FREQ_HZ    = 800000  # LED signal frequency in hertz (usually 800khz)
LED_DMA        = 10      # DMA channel to use for generating signal (try 10)
LED_BRIGHTNESS = 255     # Set to 0 for darkest and 255 for brightest
LED_INVERT     = False   # True to invert the signal (when using NPN transistor level shift)
LED_CHANNEL    = 1       # set to '1' for GPIOs 13, 19, 41, 45 or 53
gamma8 = [ 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,4,4,4,4,4,5,5,5,
    5,6,6,6,6,7,7,7,7,8,8,8,9,9,9, 10, 10, 10, 11, 11, 11, 12, 12, 13, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 24, 24, 25, 25, 26, 27, 27, 28, 29, 29, 30, 31, 32, 32, 33, 34, 35, 35, 36,
   37, 38, 39, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 50, 51, 52, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 66, 67, 68,
   69, 70, 72, 73, 74, 75, 77, 78, 79, 81, 82, 83, 85, 86, 87, 89, 90, 92, 93, 95, 96, 98, 99,101,102,104,105,107,109,110,112,114,
  115,117,119,120,122,124,126,127,129,131,133,135,137,138,140,142, 144,146,148,150,152,154,156,158,160,162,164,167,169,171,173,175,
  177,180,182,184,186,189,191,193,196,198,200,203,205,208,210,213, 215,218,220,223,225,228,231,233,236,239,241,244,247,249,252,255 ]

def pixels(child_conn,imgFile,duration):
    fps=60
    pi_pwm = GPIO.PWM(20,500)
    pi_pwm.start(0)
    im = Image.open(imgFile) 
    im = im.resize((int(duration*fps),200),5) #PIL.Image.LANCZOS
    #im.show()
    width, height = im.size
    #print(width)
    rgb_im = im.convert('RGB')
    strip = Adafruit_NeoPixel(LED_COUNT, LED_PIN, LED_FREQ_HZ, LED_DMA, LED_INVERT, LED_BRIGHTNESS, LED_CHANNEL)
    strip.begin()
#    tijd=float(tijd)
#    while (time.time()<tijd):
#        a=1
    try:
        #while loop>=1 :
            for x in range (1, width):
                #witte leds
                b,g,r = rgb_im.getpixel((x, 0))
                r = (b+g+r)/3
                r = gamma8[r]
                L = r*0.39
                pi_pwm.ChangeDutyCycle(L)
                #addressables
                for y in range (1,height):
                    b,g,r = rgb_im.getpixel((x, y))
                    r=gamma8[r]
                    g=gamma8[g]
                    b=gamma8[b]
                    strip.setPixelColor(y, Color(r,g,b))
                strip.show()
                time.sleep(1/fps)
#            #clear strip
            for y in range (1,height):
                strip.setPixelColor(y, Color(0,0,0))
            strip.show()    
            pi_pwm.ChangeDutyCycle(0)
            time.sleep(0.1)
            pi_pwm.ChangeDutyCycle(0)
                
            #print("loop:"+ str(loop))
            #loop=loop-1
        
    except KeyboardInterrupt:
            pi_pwm.ChangeDutyCycle(0)
            time.sleep(0.1)
            pi_pwm.ChangeDutyCycle(0)
            










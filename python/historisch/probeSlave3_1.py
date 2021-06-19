from multiprocessing import Process,Pipe
import time
import os


def probe(child_conn,tijd):
    os.system('sudo ifconfig wlan0 promisc')
    os.system('sudo ifconfig wlan0 down')
    os.system('sudo iwconfig wlan0 mode monitor')
    os.system('sudo ifconfig wlan0 up')
    if tijd>0:
        os.system("sudo  timeout "+str(tijd)+" tcpdump -C 10 -i wlan0 -w /home/pi/probedump.pcap -tttt -e -s 256 type mgt subtype probe-req")
    else:
        os.system("tcpdump -C 10 -i wlan0 -w /home/pi/probedump.pcap -tttt -e -s 256 type mgt subtype probe-req")
#---------
from multiprocessing import Process,Pipe
import datetime
import os
import subprocess
from subprocess import check_output

def system(child_conn,command):
    data = check_output([command], shell=True)
    file = open("/home/pi/outputDump.txt", "a+")
    file.write(str(datetime.datetime.now())+"\r\n")#
    file.write(''.join(data))#
    file.close()
    return data
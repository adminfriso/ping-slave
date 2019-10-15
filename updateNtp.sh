#!/bin/bash
exec sudo root /bin/sh - << eof
  if grep -Fxq "server 192.168.8.50" /etc/ntp.conf
  then
    # code if found
    apt install ntp -y
    echo "server 192.168.8.50" >> /etc/ntp.conf
    service ntp reload
  #else
    # code if not found
  fi

  shutdown
eof

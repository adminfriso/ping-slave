#!/bin/bash
exec sudo -u root /bin/sh - << eof
  if test -f "/etc/ntp.conf"; then
    #code if found
    if grep -Fxq "server 192.168.8.50" /etc/ntp.conf
    then
      # code if found
      shutdown
    else
      #code if found
      echo "server 192.168.8.50" >> /etc/ntp.conf
      service ntp reload
    fi
  else
    #code if not found
    apt install ntp -y
    ./updateNtp.sh
  fi

eof

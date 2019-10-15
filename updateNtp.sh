#!/bin/bash
exec sudo -u root /bin/sh - << eof
  if test -f "/etc/ntp.conf"; then
    #code if found
    if grep -Fxq "server 192.168.8.50" /etc/ntp.conf
    then
      echo "configration is done, shutting down"
      # code if found
      shutdown
    else
      #code if found
      echo "configuring ntp"
      echo "server 192.168.8.50" >> /etc/ntp.conf
      service ntp reload
    fi
  else
    #code if not found
    echo "installing ntp"
    apt install ntp -y
    ./updateNtp.sh
  fi

eof

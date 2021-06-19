#!/bin/bash
exec sudo -u root /bin/sh - << eof
  apt purge ntp -y
  sed -i s/\#NTP=/NTP\=192\.168\.8\.50/g /etc/systemd/timesyncd.conf
  timedatectl set-ntp true
  systemctl enable systemd-timesyncd
  systemctl restart systemd-timesyncd
eof

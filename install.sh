#!/bin/bash

# ------------------------------------------------------------------------------
# this script is not suitable to run as is
# it does a reboot after which the script stops
# it also uses sudo and su wich leads to un expected behaviour if run as script
# however using ssh you can copy pieces of the script to install
# ------------------------------------------------------------------------------

sudo su

#variables
login_user="pi"

# install general packages
apt update
apt upgrade
apt install -y curl git build-essential gcc make python-dev scons swig tcpdump

#install python and python packages
apt install python-pip

apt install python-pygame


## Ws2812 leds:
echo "blacklist snd_bcm2835" | tee /etc/modprobe.d/snd-blacklist.conf

sed -i 's/^#dtparam=audio=on.*/dtparam=audio=on/' /boot/config.txt

reboot

git clone https://github.com/jgarff/rpi_ws281x
cd rpi_ws281x/
sudo scons
cd python
sudo python setup.py build
sudo python setup.py install
cd ../../
## I2S Geluid
#
#sudo nano /boot/config.txt
## set the next parameters
#dtparam=i2c_arm=on
#dtparam=i2s=on
#dtparam=spi=on
##dtoverlay=lirc-rpi
#dtoverlay=hifiberry-dac
##dtparam=audio=on
sudo su
sed -i 's/^#dtparam=i2c_arm=on.*/dtparam=i2c_arm=on/' /boot/config.txt
sed -i 's/^#dtparam=i2s=on.*/dtparam=i2s=on/' /boot/config.txt
sed -i 's/^#dtparam=spi=on.*/dtparam=spi=on/' /boot/config.txt
sed -i 's/^dtoverlay=lirc-rpi.*/#dtoverlay=lirc-rpi/' /boot/config.txt
sed -i 's/^#dtoverlay=hifiberry-dac.*/dtoverlay=hifiberry-dac/' /boot/config.txt
sed -i 's/^dtparam=audio=on.*/#dtparam=audio=on/' /boot/config.txt


# install node and npm
echo "installing node and npm"
wget https://nodejs.org/dist/v8.9.0/node-v8.9.0-linux-armv6l.tar.gz
tar -xzf node-v8.9.0-linux-armv6l.tar.gz
cd node-v8.9.0-linux-armv6l
cp -R * /usr/local/
cd ../
rm -R node-v8.9.0-linux-armv6l
rm node-v8.9.0-linux-armv6l.tar.gz

echo "node version"
node -v
echo "npm version"
npm -v

echo "going to the pi user"
exit;

echo "setting node to production mode"
NODE_ENV=production

echo "installing pm2"
sudo npm install pm2@latest -g

# setup git
echo "configure git"
git config --global user.name "Friso Pi user"
git config --global user.email "ping-slave-pi@404solutions.nl"
git config --global core.editor nano
#setup repo
echo "clone git repo"
git clone https://github.com/adminfriso/ping-slave.git
echo "enter repo"
cd ping-slave
echo "creating .env file"
cp ./.env.example ./.env
# TODO: set optional variables
echo "installing dependencies"
npm install
# start server
echo "install and start node server"

sudo pm2 startup
sudo pm2 start src/index.js
sudo pm2 save

reboot

#@IgnoreInspection BashAddShebang
#no shebang, this file is to walk troug, not to execute

# ------------------------------------------------------------------------------
# this script is not suitable to run as is
# it does a reboot after which the script stops
# it also uses sudo and su wich leads to un expected behaviour if run as script
# however using ssh you can copy pieces of the script to install
# ------------------------------------------------------------------------------

sudo su

#variables
login_user="pi"

#setup wifi
cd /etc/wpa_supplicant/
cat <<EOT >> wpa_supplicant.conf

network={
    ssid="ping1"
    psk="DatKunJeWelZelfBedenken"
}

EOT

reboot
#-------------------------------------- reboot --------------------------------------

#enable ssh, setup locale, keyboard, others and P4 SPI (5 interfacing options -> P4SPI)
sudo su
raspi-config

#configure locale
#check installed locales (setted up in raspi-config)
locale -a
cd /etc/default
cat <<EOT >> locale
LANG=en_US.UTF-8
LANGUAGE=en_US.UTF-8
LC_CTYPE="en_US.UTF-8"
LC_NUMERIC="en_US.UTF-8"
LC_TIME="en_US.UTF-8"
LC_COLLATE="en_US.UTF-8"
LC_MONETARY="en_US.UTF-8"
LC_MESSAGES="en_US.UTF-8"
LC_PAPER="en_US.UTF-8"
LC_NAME="en_US.UTF-8"
LC_ADDRESS="en_US.UTF-8"
LC_TELEPHONE="en_US.UTF-8"
LC_MEASUREMENT="en_US.UTF-8"
LC_IDENTIFICATION="en_US.UTF-8"
EOT

reboot
#-------------------------------------- reboot --------------------------------------

sudo su
# install general packages
apt update
apt upgrade -y
apt install -y curl git build-essential gcc make python-dev scons swig tcpdump htop espeak

#install python and python packages
apt install -y python-pip

apt install -y python-pygame

apt install -y python-pil

apt install -y python-gpiozero

apt autoremove -y

# # Setup I2S Sound
echo "blacklist snd_bcm2835" | tee /etc/modprobe.d/snd-blacklist.conf

sed -i 's/^dtparam=audio=on.*/#dtparam=audio=on/' /boot/config.txt
sed -i 's/^#dtparam=i2c_arm=on.*/dtparam=i2c_arm=on/' /boot/config.txt
sed -i 's/^#dtparam=i2s=on.*/dtparam=i2s=on/' /boot/config.txt
sed -i 's/^#dtparam=spi=on.*/dtparam=spi=on/' /boot/config.txt
sed -i 's/^dtoverlay=lirc-rpi.*/#dtoverlay=lirc-rpi/' /boot/config.txt
sed -i 's/^dtparam=audio=on.*/#dtparam=audio=on/' /boot/config.txt
echo "dtoverlay=hifiberry-dac" >> /boot/config.txt

# Ws2812 leds:
cd ~
git clone https://github.com/jgarff/rpi_ws281x
cd rpi_ws281x/
scons
cd python
python setup.py build
python setup.py install
cd ../../
rm -r rpi_ws281x/

reboot
#-------------------------------------- reboot --------------------------------------

sudo su
pip install rpi_ws281x

#validate spi_bcm2835 (check if it )
lsmod | grep spi

#if the spi module is not activated edit boot config
# if activated
sudo nano /boot/config.txt
# set config
dtparam=spi=on
# else just continue

pip install spidev

pip install mfrc522

# setup time
apt purge ntp -y
sed -i s/\#NTP=/NTP\=192\.168\.8\.50/g /etc/systemd/timesyncd.conf
timedatectl set-ntp true
systemctl enable systemd-timesyncd
systemctl restart systemd-timesyncd

# install node and npm (node is not higher than 8.9 on armV6l hardware)
echo "installing node and npm"
cd ~
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

echo "update npm"

npm install -g npm

npm -v

#also execute the next commands as root

echo "setting node to production mode"
NODE_ENV=production

echo "installing pm2"
npm install pm2 -g

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
echo "creating .env file directed for production usage"
cp ./.env.pi ./.env

echo "installing dependencies"
npm install
# start server
echo "install and start node server"

pm2 startup
pm2 start src/index.js
pm2 save

reboot
#-------------------------------------- reboot --------------------------------------

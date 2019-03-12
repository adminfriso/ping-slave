#!/bin/bash

# install node and npm
echo "installing node and npm"
wget https://nodejs.org/dist/v8.9.0/node-v8.9.0-linux-armv6l.tar.gz
tar -xzf node-v8.9.0-linux-armv6l.tar.gz
cd node-v8.9.0-linux-armv6l
sudo cp -R * /usr/local/
# TODO: sudo will need an input pipeline for the password
echo "node version"
node -v
echo "npm version"
npm -v

#install and setup git

sudo apt install -y git
# TODO: sudo will need an input pipeline for the password
cd ../

git config --global user.name "Friso Pi user"
git config --global user.email "ping-slave-pi@404solutions.nl"

git config --global core.editor nano

git clone https://github.com/adminfriso/ping-slave.git

cd ping-slave

npm install

cd src

node index.js

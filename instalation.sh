#!/bin/bash

# install node and npm
echo "installing node and npm"
wget https://nodejs.org/dist/v8.9.0/node-v8.9.0-linux-armv6l.tar.gz
tar -xzf node-v8.9.0-linux-armv6l.tar.gz
cd node-v8.9.0-linux-armv6l
sudo cp -R * /usr/local/
cd ../
# TODO: sudo will need an input pipeline for the password
echo "node version"
node -v
echo "npm version"
npm -v
echo "setting node to production mode"
NODE_ENV=production
#install and setup git
echo "installing git"
sudo apt install -y git
# TODO: sudo will need an input pipeline for the password
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
echo "start node server"
node src/index.js

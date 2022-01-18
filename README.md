# ping-slave

This is the Client side application ran on the beacons used by the ping project. 
It is a node.js server application which will be used as websocket client for the server application, found in the repo [ping-master](https://github.com/adminfriso/ping-master).

This repo features:
* Receiving files, and store them to the storage or storage/temp folder.
* Getting files from the filesystem and upload it to the socket.
* Deleting files.
* Executing commands on the beacon.
* Return the serial number of the raspberry pi as identification of the beacon for the master project.
* Return the git version number.
* Executing python commands on the beacon.

# Raspberry usefull links
* [Install clean distro using MAC OSX](https://www.macworld.co.uk/how-to/mac/how-to-set-up-raspberry-pi-3-with-mac-3637490/)
* [Enable SSH](https://www.raspberrypi.org/documentation/remote-access/ssh/)
* [Wireless (cli)](https://www.raspberrypi.org/documentation/configuration/wireless/wireless-cli.md)

# Getting Started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes. 
See deployment for notes on how to deploy the project on a live system eg the beacons.

## Prerequisites

What things you need to install the software and how to install them
 
 * [Node.js](https://nodejs.org/en/download/)
 * NPM (installed with Node.js)
 * Common sense ;)

## Installing

A step by step series of examples that tell you how to get a development env running.
There is not a lot into it.

####Project setup
```
npm install
```

#### Compiles and hot-reloads for development
this uses nodemon
```
npm run serve
```

## Deployment
First setup a wifi connection to connect with

https://www.raspberrypi.org/documentation/configuration/wireless/wireless-cli.md

Then enable ssh 

https://www.raspberrypi.org/documentation/remote-access/ssh/

Then run installation guide

Then next part is pointed at the installation of node, this is also present in install.sh
### Node
set the environment to production
```bash
NODE_ENV=production
```
copy the env variable and edit it if the configuration does not meet the current system
```bash
cp .env.example .env
# optional if the configuration does not meet the current system
nano .env
```
install the packages
```bash
npm install
```
run on production, the & is to run it in the background
```bash
node src/index.js &
```

## Updating
here we will not assume you use pm2, if you do use it, forget the commands ```fg and node src/index.js &```

```bash
fg
# then type CTRL+C
git pull
git reset HEAD --hard
npm install
node src/index.js &
```


# Development

## Python development
pm2 stopzetten om te testen: ```sudo pm2 stop index```

Git directory: ```cd /root/ping-slave```

Python directory: ```cd /root/ping-slave/python```

python (2.7) executen vanuit een los terminal window ```python ping.py```

python stoppen vanuit een ander terminal window  ```pkill -f ping.py```

## commando's om te sturen
s,../storage/audio/Ab/ab.wav,0.05
i,../storage/lichtbeeld/8.jpg,2
e,statusoff
e,statuson

# Built With
* [Node.js](https://nodejs.org/en/docs/) - The server framework used
* [socket.io-client](https://socket.io/docs/client-api/) - Socket.io client. The client version for the websockets

# Authors
* **Friso Modderman - 404 solutions** - *Developer & Node.js* - [adminfriso](https://github.com/adminfriso)
* **Gijs van Bon - van Bon** - *Artist & Python* - [GvBon](https://github.com/GvBon)



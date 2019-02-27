# ping-slave

This is the Client side application ran on the beacons used by the ping project. 
It is a node.js server application which will be used as websocket client for the server application, found in the repo [ping-master](https://github.com/adminfriso/ping-master).

This repo features:
* Receiving files, and store them to the storage folder
* Executing commands on the beacon.
* Return the serial number of the raspberry pi as identification of the beacon for the master project.

## TODO and usefull links

https://www.digitalocean.com/community/tutorials/how-to-set-up-a-node-js-application-for-production-on-ubuntu-16-04

https://www.npmjs.com/package/python-shell

https://flaviocopes.com/node-difference-dev-prod/

TODO: 
* python native support
* remove socketExample when finished
* installation guide for production

## Getting Started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes. 
See deployment for notes on how to deploy the project on a live system eg the beacons.

### Prerequisites

What things you need to install the software and how to install them
 
 * [Node.js](https://nodejs.org/en/download/)
 * NPM (installed with Node.js)
 * Common sense ;)

### Installing

A step by step series of examples that tell you how to get a development env running.
There is not a lot into it.

#### Project setup
```
npm install
```

##### Compiles and hot-reloads for development
this uses nodemon
```
npm run serve
```

### Deployment

#### webserver

### Updating


## Built With
* [Node.js](https://nodejs.org/en/docs/) - The server framework used
* [socket.io-client](https://socket.io/docs/client-api/) - Socket.io client. The client version for the websockets

## Authors

* **Friso Modderman - 404 solutions** - *Initial work* - [adminfriso](https://github.com/adminfriso)

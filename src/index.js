'use strict';
const requiredir = require("requiredir");
global.config = requiredir('./config');
global.services = requiredir('./services');
global.connections = requiredir("./connections");
const {exec} = require('child_process');
global.exec = exec;

connections.macAddress();
connections.executeCommand();
connections.socketExample();

'use strict';
const requiredir = require("requiredir");
const connections = requiredir("./connections");

connections.macAddress();
connections.executeCommand();
connections.socketExample();

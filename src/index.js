'use strict';
require('dotenv').config();
const requiredir = require("requiredir");
global.config = requiredir('./config');
global.services = requiredir('./services');
global.connections = requiredir("./connections");
const {exec} = require('child_process');
global.exec = exec;

connections.serialNumber();
connections.executeCommand();
connections.executePython();
connections.fileUpload();
connections.tempFileUpload();
connections.fileDownload();

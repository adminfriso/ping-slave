'use strict';
// Make connection
const io = require('socket.io-client');
exports.socket = io.connect('http://localhost:4000');

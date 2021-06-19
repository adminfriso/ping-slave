'use strict';
// Make connection
const io = require('socket.io-client');
module.exports = io.connect(config.socket.url);

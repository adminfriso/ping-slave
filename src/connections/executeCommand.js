'use strict';
const {socket} = require('../config/socket');
const {exec} = require('child_process');

module.exports = () => {
// receive data from the server
    socket.on('execute-command', function (data) {
        exec(data.command, (err, stdout, stderr) => {
            if (err) {
                // node couldn't execute the command
                return;
            }
            let response = {};
            response.stdout = stdout;
            response.stderr = stderr;
            // send data to the server
            socket.emit('execute-command', response);
        });
    });
};
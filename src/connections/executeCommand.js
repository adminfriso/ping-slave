'use strict';
const {socket} = require('../config/socket');
const {exec} = require('child_process');

module.exports = () => {
// receive data from the server
    socket.on('execute-command', (data) => {
        if (data == null){
            socket.emit('execute-command', null);
            return;
        }
        exec(data.command, (err, stdout, stderr) => {
            if (err) {
                // node couldn't execute the command
                return;
            }
            let response = {
                stdout,
                stderr,
            };
            // send data to the server
            socket.emit('execute-command', response);
        });
    });
};
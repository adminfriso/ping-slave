'use strict';
const {socket} = require('../config/socket');
const {exec} = require('child_process');

module.exports = () => {
    const piGetMacAddressPattern = "/eth0.*\n.*\n.*\n.*ether (..:..:..:..:..:..)/gm";
    const appleGetMacAddressPattern = /ether (..:..:..:..:..:..)/gm;
    // Receive mac address via execute command and return it on the socket
    exec('ifconfig -a', (err, stdout, stderr) => {
        if (err) {
            // node couldn't execute the command
            return;
        }
        const regResult = new RegExp(appleGetMacAddressPattern).exec(stdout);
        // send mac address to server
        socket.emit('mac-address', regResult[1]);
        // the *entire* stdout and stderr (buffered)
        // console.log(`stdout: ${stdout}`);
        // console.log(`stderr: ${stderr}`);
    })
};
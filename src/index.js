'use strict';
// Make connection
const io = require('socket.io-client');
const socket = io.connect('http://localhost:4000');
// Receive mac address via execute command
const {exec} = require('child_process');

const piGetMacAddressPattern = /ether (..:..:..:..:..:..)/gm;
let piMacAddress = 'error';
exec('ifconfig -a', (err, stdout, stderr) => {
    if (err) {
        // node couldn't execute the command
        return;
    }
    piMacAddress = new RegExp(piGetMacAddressPattern).exec(stdout)[1];
    // the *entire* stdout and stderr (buffered)
    // console.log(`stdout: ${stdout}`);
    // console.log(`stderr: ${stderr}`);

});
// send mac address to server
socket.emit('macAddress', piMacAddress);

// ----------test and example
const testDataObjectToServer = {
    piMacAddress,
};
// receive data from the server
socket.on('test', function (data) {
    // console.log(data.name);
});
// send data to the server
socket.emit('chat', testDataObjectToServer);

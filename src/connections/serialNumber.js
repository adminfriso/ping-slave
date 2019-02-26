'use strict';

module.exports = () => {
    const piPattern = "/eth0.*\n.*\n.*\n.*ether (..:..:..:..:..:..)/gm";
    const piCommand = 'cat /proc/cpuinfo | grep ^Serial | cut -d":" -f2';
    const applePattern = /ether (..:..:..:..:..:..)/gm;
    const appleCommand = 'ioreg -l | grep IOPlatformSerialNumber';

    const pattern = applePattern;
    const command = appleCommand;

    services.socket.on('mac-address', function () {
        // Receive mac address via execute command and return it on the socket
        exec(command, (err, stdout, stderr) => {
            if (err) {
                // node couldn't execute the command
                return;
            }

            const regResult = new RegExp(pattern).exec(stdout);
            // send mac address to server
            let response = {
              serialNumber: regResult[1],
            };
            services.socket.emit('serial-number', response);
            // the *entire* stdout and stderr (buffered)
            // console.log(`stdout: ${stdout}`);
            // console.log(`stderr: ${stderr}`);
        });
    });

};

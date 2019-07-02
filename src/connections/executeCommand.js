'use strict';

module.exports = () => {
// receive data from the server
    services.socket.on('execute-command', (command) => {
        if (command == null){
            services.socket.emit('execute-command', null);
            return;
        }
        if (command === 'sudo reboot'){
          services.socket.emit('execute-command', {
            command: "sudo reboot",
            status: "received but doing an early callback",
          });
        }
        exec(command, (err, stdout, stderr) => {
            if (err) {
                // node couldn't execute the command
                services.socket.emit('execute-command', err);
            }
            let response = {
                stdout,
                stderr,
            };
            // send data to the server
            services.socket.emit('execute-command', response);
        });
    });
};

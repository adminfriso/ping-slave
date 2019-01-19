'use strict';

module.exports = () => {
// receive data from the server
    services.socket.on('execute-command', (data) => {
        if (data == null){
            services.socket.emit('execute-command', null);
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
            services.socket.emit('execute-command', response);
        });
    });
};
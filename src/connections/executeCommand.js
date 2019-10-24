'use strict';

module.exports = () => {
// receive data from the server
  services.socket.on('execute-command', (command) => {
    if (command == null) {
      services.socket.emit('execute-command', {
        success: true,
        status: "Command is empty.",
      });
      return;
    }
    if (command === 'sudo reboot') {
      services.socket.emit('execute-command', {
        success: true,
        command: "sudo reboot",
        status: "Received but doing an early callback.",
      });
      return;
    }
    exec(command, (err, stdout, stderr) => {
      if (err) {
        services.socket.emit('execute-command', {
          success: false,
          status: "Node couldn't execute the command.",
          err
        });
      }
      let response = {
        success: true,
        status: "Command executed.",
        command,
        stdout,
        stderr,
      };
      // send data to the server
      services.socket.emit('execute-command', response);
    });
  });
};

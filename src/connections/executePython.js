'use strict';

module.exports = () => {
  // initialize python
  let { PythonShell } = require('python-shell');
  let pyShell = new PythonShell('python/PiMaster3_1.py');


  // receive data from the server
  services.socket.on('execute-python', (command) => {
    if (command == null) {
      services.socket.emit('execute-python', null);
      return;
    }

    pyShell.send(command);
    // message? => command?
    pyShell.on('s/i,time,file,volume,loop>', function (response) {
      console.log(response);
      services.socket.emit('execute-python', response);
      // received a message sent from the Python script (a simple "print" statement)
    });
  });
};

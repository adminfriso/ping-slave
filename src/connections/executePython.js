'use strict';

module.exports = () => {
  // initialize python
  let { PythonShell } = require('python-shell');
  let pyShell = null;
  if (process.env.DEVICE !== 'apple') {
    console.log('starting python');
    pyShell = new PythonShell('./python/PiMaster3_1.py', {
      mode: 'text',
      // pythonOptions: ['-u'],
      pythonPath: '/usr/bin/python2.7'
    });
    console.log('started python');
  }
  // pyShell.end((err, exitCode, exitSignal) => {
  //   console.log('python exited with:');
  //   console.log('error:');
  //   console.log(err);
  //   console.log('The exit code was: ' + exitCode);
  //   console.log('The exit signal was: ' + exitSignal);
  // });

  // receive data from the server
  services.socket.on('execute-python', (command) => {
    if (command == null) {
      services.socket.emit('execute-python', null);
      return;
    }
    pyShell.send(command);

    let response = {
      success: true,
    };

    services.socket.emit('execute-python', response);

    //TODO: for now we will do an early return with the fact that the message is sent
    // let responseMessage = '';
    // // console.log('setting timer reply with timeout of 50ms');
    // // let responseTimer = setTimeout(reply, 50);
    // pyShell.on('message', function (message) {
    //   // handle message (a line of text from stdout)
    //   console.log('response from python: ' + message);
    //   responseMessage = responseMessage + message;
    //   reply();
    //   // console.log('clearing timer');
    //   // clearTimeout(responseTimer);
    //   // console.log('setting timer reply with timeout of 50ms');
    //   // responseTimer = setTimeout(reply, 50);
    // });
    //
    // function reply() {
    //   let response = {
    //     message: responseMessage,
    //   };
    //   services.socket.emit('execute-python', response);
    // }

    // pyShell.send(command).end(function (err) {
    //   if (err) console.log(err);
    //   else console.log('reached');
    // });

  });


};

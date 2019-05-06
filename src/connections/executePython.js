'use strict';

module.exports = () => {
  // initialize python
  let { PythonShell } = require('python-shell');
  console.log('starting python');
  let pyShell = new PythonShell('./python/PiMaster3_1.py');
  console.log('started python');
  pyShell.mode = 'text';
  pyShell.pythonPath = '/usr/bin/python2.7';
  // pyShell.mode = 'text';

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
    console.log('send command to python');
    console.log(command);
    pyShell.send(command);
    // console.log(pyShell.stdout);
    pyShell.on('message', function (message) {
      // handle message (a line of text from stdout)
      let response = {
                message,
            };
      services.socket.emit('execute-python', response);
    });

    // pyShell.send(command).end(function (err) {
    //   if (err) console.log(err);
    //   else console.log('reached');
    // });

 //    pyShell.stdout.on('data', function(data) {
 //    // if (data == 'data'){
 //    //     pyShell.send('go').end(function(err){
 //    //         if (err) console.error(err);
 //    //         // ...
 //    //     });}
 //    // else if (data == 'data2'){
 //    //     pyShell.send('OK').end(function(err){
 //    //         if (err) console.error(err);
 //    //         // ...
 //    //     });}
 //    console.log(data);
 // });

    // message? => command?
    // pyShell.stdout.on('data', function (response) {
    //   console.log(response);
    //   services.socket.emit('execute-python', response);
    //   // received a message sent from the Python script (a simple "print" statement)
    // });
  });


};

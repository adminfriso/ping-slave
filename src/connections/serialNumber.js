'use strict';

module.exports = () => {
  const piPattern = /\s(\S*)/gm;
  const piCommand = 'cat /proc/cpuinfo | grep ^Serial | cut -d":" -f2';
  const applePattern = /"(\w{12})"/gm;
  const appleCommand = 'ioreg -l | grep IOPlatformSerialNumber';

  let pattern = piPattern;
  let command = piCommand;

  if (process.env.DEVICE === 'apple') {
    pattern = applePattern;
    command = appleCommand;
  }


  services.socket.on('serial-number', () => {
    // Receive mac address via execute command and return it on the socket

    exec(command, (err, stdout, stderr) => {
      if (err) {
        // node couldn't execute the command
        return;
      }
      const regResult = new RegExp(pattern).exec(stdout);
      // send serial number to server
      exec('git rev-parse --short HEAD', (err, stdoutGit, stderrGit) => {
        if (err) {
          // node couldn't execute the command
          return;
        }
        exec("ifconfig wlan0 | grep inet | awk '{ print $2 }'", (err, stdoutWLan0, stderrWLan0) => {
          if (err) {
            // node couldn't execute the command
            return;
          }
          exec("ifconfig wlan1 | grep inet | awk '{ print $2 }'", (err, stdoutWLan1, stderrWLan1) => {
            if (err) {
              // node couldn't execute the command
              return;
            }
            let response = {
              serialNumber: regResult[1],
              gitVersionNumber: stdoutGit,
              wLan0: stdoutWLan0,
              wLan1: stdoutWLan1,
            };
            services.socket.emit('serial-number', response);
          });
        });
      });
      // the *entire* stdout and stderr (buffered)
      // console.log(`stdout: ${stdout}`);
      // console.log(`stderr: ${stderr}`);
    });
  });

};

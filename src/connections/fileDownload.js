'use strict';
const fs = require('fs');
module.exports = () => {
  services.socket.on('file-download', (path) => {
    if (path == null) {
      services.socket.emit('file-download', null);
      return;
    }
    fs.readFile(path, function (err, data) {
      if (err) {
        services.socket.emit('file-download', err);
        return;
      }
      services.socket.emit('file-download', data);
    });
  });

};

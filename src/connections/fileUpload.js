'use strict';
const fs = require('fs');
module.exports = () => {
  services.socket.on('file-upload', (file) => {
    fs.writeFile("storage/" + file.name, file.data, function (err) {
      if (err) {
        services.socket.emit('file-upload', {
          success: false,
          message: "File upload errored on the beacon.",
          err,
        });
        return;
      }
      let response = {
        success: true,
        message: "Uploaded file to storage folder.",
      };
      services.socket.emit('file-upload', response);
    });
  });

};

'use strict';
const fs = require('fs');
const rimraf = require('rimraf');

module.exports = () => {
  services.socket.on('temp-file-upload', (file, path) => {
    let basePath = "storage/temp/" + path;
    if (!fs.existsSync(basePath)) {
      fs.mkdirSync(basePath);
    }
    fs.writeFile(basePath + file.name, file.data, function (err) {
      if (err) {
        services.socket.emit('temp-file-upload', {
          success: false,
          message: "Temp file upload errored on the beacon.",
          err,
        });
        return;
      }
      let response = {
        success: true,
        message: "Uploaded file to "+ basePath +" folder.",
      };
      services.socket.emit('temp-file-upload', response);
    });
  });

  services.socket.on('temp-file-delete', () => {
    console.log('removed temp folder content');
    rimraf('./storage/temp/*', () => {
      let response = {
        success: true,
        message: "Deleted content of storage/temp folder.",
      };
      services.socket.emit('temp-file-delete', response);
    });
  });
};

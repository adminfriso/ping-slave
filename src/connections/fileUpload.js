'use strict';
const fs = require('fs');
module.exports = () => {
  services.socket.on('file-upload', (file, path) => {
    let basePath = "storage/" + path;
    if (!fs.existsSync(basePath)) {
      fs.mkdirSync(basePath);
    }
    fs.writeFile(basePath + file.name, file.data, function (err) {
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
        message: "Uploaded file to " + basePath + " folder.",
      };
      services.socket.emit('file-upload', response);
    });
  });

};

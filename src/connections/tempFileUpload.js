'use strict';
const fs = require('fs');
const rimraf = require('rimraf');

rimraf('./storage/temp/*', function () { console.log('removed temp folder content'); });

module.exports = () => {
    services.socket.on('temp-file-upload', function (file) {
      console.log('received something');
      fs.writeFile("storage/temp" + file.name, file.data, function(err) {
            if(err) {
                services.socket.emit('temp-file-upload', err);
                return;
            }
            let response = {
              success: true,
            };
            services.socket.emit('temp-file-upload', response);
        });
    });

};

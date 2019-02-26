'use strict';
const fs = require('fs');
module.exports = () => {
    services.socket.on('file-upload', function (file) {
        fs.writeFile("storage/" + file.name, file.data, function(err) {
            if(err) {
                services.socket.emit('file-upload', err);
                return;
            }
            let response = {
              uploaded: true,
            };
            services.socket.emit('file-upload', response);
        });
    });

};

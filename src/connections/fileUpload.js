'use strict';
const fs = require('fs');
module.exports = () => {
    services.socket.on('file-upload', function (file) {
        fs.writeFile("storage/" + file.name, file.data, function(err) {
            if(err) {
                services.socket.emit('file-upload', err);
                return;
            }
            services.socket.emit('file-upload', 'File uploaded!');
        });
    });

};
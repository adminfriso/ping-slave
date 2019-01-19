'use strict';

module.exports = () => {
    // ----------test and example
    const testDataObjectToServer = {
        bernard: 'green',
    };
// receive data from the server
    services.socket.on('test', function (data) {
        // console.log(data.name);
    });
// send data to the server
    services.socket.emit('chat', testDataObjectToServer);
};
const {socket} = require('../config/socket');

module.exports = () => {
    // ----------test and example
    const testDataObjectToServer = {
        bernard: 'green',
    };
// receive data from the server
    socket.on('test', function (data) {
        // console.log(data.name);
    });
// send data to the server
    socket.emit('chat', testDataObjectToServer);
};
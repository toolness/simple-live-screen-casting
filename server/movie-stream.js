var stream = require('stream'),
    BufferedStream = require('./buffered-stream').BufferedStream;

function MovieStream() {
  var self = new stream.Stream();
  self.readable = true;
  self.write = function(chunk) {
    self.emit('data', chunk);
  };
  self.end = function() {
    self.readable = false;
    self.emit('end');
  };
  return self;
}

exports.BufferedStreamingMovie = function BufferedStreamingMovie(duration) {
  var self = new Object();
  var inputStream = new MovieStream();
  var bufferedStream = new BufferedStream(inputStream);

  self.duration = duration;
  
  self.createReadableStream = function createReadableStream() {
    return bufferedStream.clone();
  };

  self.write = function write(chunk) {
    inputStream.write(chunk);
  };
  
  self.end = function end() {
    inputStream.end();
  };
  
  return self;
};

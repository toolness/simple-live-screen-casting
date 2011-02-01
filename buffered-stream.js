// The BufferedStream is a simple wrapper for an input stream that 
// remembers its contents, so that at any time it can be easily cloned
// and read from the beginning by multiple clients, regardless of
// whether the original input stream has ended.

var stream = require('stream');

function BufferedStream(inputStream, chunks) {
  var self = new stream.Stream();
  var pos = 0;
  var isPaused = true;
  var isEnded = !inputStream.readable;
  var wasEndSent = false;

  //if (chunks)
  //  console.log("chunks is", chunks.length);
  chunks = chunks ? chunks.slice() : [];

  function emitChunks() {
    if (!isPaused) {
      //console.log("EMITCHUNX", pos, chunks.length);
      while (pos < chunks.length) {
        //console.log("DATAZ");
        self.emit('data', chunks[pos++]);
      }
      if (pos >= chunks.length && isEnded && !wasEndSent) {
        //console.log("ENDZ");
        self.readable = false;
        wasEndSent = true;
        self.emit('end');
      }
    }
  }

  self.readable = true;
  
  self.clone = function() {
    return BufferedStream(inputStream, chunks);
  };
  
  self.pause = function() {
    //console.log('PAUSE');
    isPaused = true;
  };
  
  self.resume = function() {
    //console.log('RESUME');
    isPaused = false;
    emitChunks();
  };

  self.destroy = function() {
    //console.log('DESTROY');
    pos = Infinity;
    isEnded = true;
    wasEndSent = true;
    chunks.splice(0);
  }

  self.destroySoon = self.destroy;

  self.inputStream = inputStream;

  inputStream.on('data', function(chunk) {
    if (!isEnded) {
      chunks.push(chunk);
      emitChunks();
    }
  });

  inputStream.on('end', function() {
    isEnded = true;
    emitChunks();
  });

  return self;
}

exports.BufferedStream = BufferedStream;

// curl -i http://localhost:8080/movie/296.ogg --raw

var http = require('http'),
    io = require('./socket.io'),
    fs = require('fs'),
    sys = require('sys'),
    url = require('url'),
    stream = require('stream'),
    bstream = require('./buffered-stream');

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

var MOVIE_LIFETIME = 30000;
var STATIC_FILES_DIR = './static-files';
var INDEX_FILE = '/index.html';
var STATIC_FILES = {
  '/index.html': 'text/html'
, '/jquery.min.js': 'application/javascript'
};

var inUpdate = false;

var movies = {};

var currMovieID;
var currMovieSize;

var server = http.createServer(function(req, res) {
  var info = url.parse(req.url);
  var path = info.pathname == '/' ? INDEX_FILE : info.pathname;

  console.log(req.method, path);

  if (path in STATIC_FILES) {
    res.writeHead(200, {'Content-Type': STATIC_FILES[path]});
    var file = fs.createReadStream(STATIC_FILES_DIR + path);
    sys.pump(file, res);
  } else if (path == '/clear') {
    for (var movieID in movies)
      delete movies[movieID];
    currMovieID = undefined;
    inUpdate = false;
    res.writeHead(200, 'OK', {'Content-Type': 'text/plain'});
    res.end('Deleted all streaming data.');
  } else if (path == '/update') {
    if (inUpdate) {
      console.warn("concurrent updates detected! they should be serial.");
    }
    inUpdate = true;
    var kind = req.headers['x-theora-kind'];
    var movieID = parseInt(req.headers['x-theora-id']);
    if (!(movieID in movies)) {
      if (currMovieID !== undefined) {
        console.log("movie #" + currMovieID + " uploaded (" +
                    currMovieSize + " bytes).");
        movies[currMovieID].inputStream.end();
        setTimeout(function() {
          if (movieID in movies) {
            console.log("freeing movie #" + movieID);
            delete movies[movieID];
          }
        }, MOVIE_LIFETIME);
      }
      if (kind == "start") {
        currMovieID = movieID;
        currMovieSize = 0;
        console.log("beginning upload of movie #" + movieID);
        movies[movieID] = new bstream.BufferedStream(new MovieStream());
        clients.sendAll(movieID.toString());
      } else
        console.warn("expected first packet to be of kind 'start'!");
    }
    if (movieID in movies)
      req.on('data', function(chunk) {
        currMovieSize += chunk.length;
        movies[movieID].inputStream.write(chunk);
      });
    req.on('end', function(end) {
      res.writeHead(200, 'OK', {'Content-Type': 'text/plain'});
      res.end('Thanks bud.');
      inUpdate = false;
    });
  } else {
    //console.log("CONNECTION IS " + req.connection);
    var movieMatch = path.match(/\/movie\/(\d+)\.ogg/);
    //console.log(path, JSON.stringify(req.headers));
    if (movieMatch) {
      var movieID = parseInt(movieMatch[1]);
      if (movieID in movies) {
        console.log('streaming movie', movieID);
        res.writeHead(200, 'OK', {
          'Content-Type': 'video/ogg',
          'X-Content-Duration': '2.0'
          //,'Connection': 'close'
        });
        var newStream = movies[movieID].clone();
        
        res.on('error', function(e) {
          //console.log('OMG EXCEPTION ' + e);
        });
        newStream.on('data', function(chunk) {
          res.write(chunk);
        });
        newStream.on('end', function() {
          //console.log("ENDING RESPONSE NOW.");
          res.end();
        });
        //newStream.pipe(res);
        newStream.resume();
        return;
      }
    }
    res.writeHead(404, 'Not Found', {'Content-Type': 'text/plain'});
    res.end('Not Found: ' + path);
  }
});

var socket = io.listen(server, {
  transports: [
  'websocket'
, 'htmlfile'
, 'xhr-multipart'
, 'xhr-polling'
  ]
});

var clients = [];
clients.sendAll = function(string) {
  clients.forEach(function(client) {
    client.send(string);
  });
};

socket.on('connection', function(client) {
  console.log("CONNECT");
  clients.push(client);
  client.on('message', function(contents) {
    console.log("MESSAGE", contents);
  });
  client.on('disconnect', function() {
    clients.splice(clients.indexOf(client), 1);
    console.log("DISCONNECT");
  });
});

server.listen(8080);

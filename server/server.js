// This is a simple node.js server that allows a Desktop client to stream
// in lots of Ogg Theora clips, which are streamed to browser clients and
// stitched-together on the client side.

var http = require('http'),
    io = require('./socket.io'),
    fs = require('fs'),
    sys = require('sys'),
    url = require('url'),
    movieStream = require('./movie-stream');

// TODO: This lifetime should really be dependent on the duration
// of the clip being stored.
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
    var duration = parseInt(req.headers['x-content-duration']);
    if (!(movieID in movies)) {
      if (currMovieID !== undefined) {
        console.log("movie #" + currMovieID + " uploaded (" +
                    currMovieSize + " bytes).");
        movies[currMovieID].end();
        setTimeout(function() {
          if (movieID in movies) {
            console.log("freeing movie #" + movieID);
            delete movies[movieID];
            if (movieID == currMovieID)
              currMovieID = undefined;
          }
        }, MOVIE_LIFETIME);
      }
      if (kind == "start") {
        currMovieID = movieID;
        currMovieSize = 0;
        console.log("beginning upload of movie #" + movieID);
        movies[movieID] = new movieStream.BufferedStreamingMovie(duration);
        clients.sendAll(movieID + ' ' + duration);
      } else
        console.warn("expected first packet to be of kind 'start'!");
    }
    if (movieID in movies)
      req.on('data', function(chunk) {
        currMovieSize += chunk.length;
        movies[movieID].write(chunk);
      });
    req.on('end', function(end) {
      res.writeHead(200, 'OK', {'Content-Type': 'text/plain'});
      res.end('Thanks bud.');
      inUpdate = false;
    });
  } else {
    var movieMatch = path.match(/\/movie\/(\d+)\.ogg/);
    if (movieMatch) {
      var movieID = parseInt(movieMatch[1]);
      if (movieID in movies) {
        console.log('streaming movie', movieID);
        var newStream = movies[movieID].createReadableStream();
        
        var headers = {
          'Content-Type': 'video/ogg',
          'X-Content-Duration': movies[movieID].duration.toString()
        };

        function sendStream(newStream) {
          res.writeHead(200, 'OK', headers);

          newStream.on('data', function(chunk) {
            res.write(chunk);
          });
          newStream.on('end', function() {
            res.end();
          });
          newStream.resume();
        }

        if ('user-agent' in req.headers &&
            req.headers['user-agent'].indexOf('Chrome') != -1) {

          // Chrome seems to really want us to provide content length
          // and not use chunked transfer encoding, so we'll play
          // it their way, but that means Chrome clients will have
          // higher latency than others.

          function sendToChrome(newStream) {
            headers['Content-Length'] = newStream.bufferedLength.toString();
            sendStream(newStream);
          }

          if (!newStream.isFullyBuffered) {
            newStream.on('end', function() {
              sendToChrome(newStream.clone());
            });
            newStream.resume();
          } else
            sendToChrome(newStream);
        } else
          sendStream(newStream);

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

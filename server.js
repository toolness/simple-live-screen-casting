var http = require('http'),
    io = require('./socket.io'),
    fs = require('fs'),
    sys = require('sys'),
    url = require('url');

var STATIC_FILES_DIR = './static-files'
var INDEX_FILE = '/index.html';
var STATIC_FILES = {
  '/index.html': 'text/html'
, '/jquery.min.js': 'application/javascript'
};

var inUpdate = false;

var server = http.createServer(function(req, res) {
  var info = url.parse(req.url);
  var path = info.pathname == '/' ? INDEX_FILE : info.pathname;

  console.log("path", path);

  if (path in STATIC_FILES) {
    res.writeHead(200, {'Content-Type': STATIC_FILES[path]});
    var file = fs.createReadStream(STATIC_FILES_DIR + path);
    sys.pump(file, res);
  } else if (path == '/update') {
    if (inUpdate) {
      throw new Error("concurrent updates detected! they must be serial.");
    }
    inUpdate = true;
    var kind = req.headers['x-theora-kind'];
    var movieID = parseInt(req.headers['x-theora-id']);
    clients.sendAll('k' + kind);
    console.log("update", kind);
    req.on('data', function(chunk) {
      //console.log("chunk", chunk.length);//, typeof(chunk), chunk.toString('base64'));
      clients.sendAll('c' + chunk.toString('base64'));
    });
    req.on('end', function(end) {
      //console.log("end");
      res.writeHead(200, 'OK', {'Content-Type': 'text/plain'});
      res.end('Thanks bud.');
      clients.sendAll('e' + movieID);
      inUpdate = false;
    });
  } else {
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

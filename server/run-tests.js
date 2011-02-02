var assert = require('assert'),
    bufferedStream = require('./buffered-stream');

var tests = [];

tests.push(function bufferedStreamTests() {
  var events = require('events');
  var BufferedStream = bufferedStream.BufferedStream;
  
  var inStream = new events.EventEmitter();
  inStream.readable = true;
  var stream = new BufferedStream(inStream);
  var buf1 = new Buffer(5);
  var buf2 = new Buffer(10);
  assert.equal(stream.bufferedLength, 0);
  assert.strictEqual(stream.isFullyBuffered, false);
  inStream.emit('data', buf1);
  assert.equal(stream.bufferedLength, 5);
  assert.strictEqual(stream.isFullyBuffered, false);
  inStream.emit('data', buf2);
  assert.equal(stream.bufferedLength, 15);
  assert.strictEqual(stream.isFullyBuffered, false);
  inStream.emit('end');
  assert.strictEqual(stream.isFullyBuffered, true);
  assert.deepEqual(stream.bufferedChunks, [buf1, buf2]);
});

tests.forEach(function(testSuiteFunction) {
  console.log("Running test suite: " + testSuiteFunction.name + "...");
  testSuiteFunction();
});

console.log("Done, all tests passed!");

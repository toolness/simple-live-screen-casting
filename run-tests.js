var assert = require('assert'),
    byteRanges = require('./byte-ranges'),
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

tests.push(function byteRangesTests() {
  assert.deepEqual(byteRanges.parseHeader('bytes=OMNOM'), null);

  assert.deepEqual(byteRanges.parseHeader('bytes=1-2'), {
    start: 1,
    end: 2
  });

  assert.deepEqual(byteRanges.parseHeader('bytes=1-'), {
    start: 1,
    end: null
  });

  assert.strictEqual(byteRanges.hasRange(5, 0, 4), true);
  assert.strictEqual(byteRanges.hasRange(5, 0, 5), false);
  assert.strictEqual(byteRanges.hasRange(5, 0, null), true);
  assert.strictEqual(byteRanges.hasRange(5, 3, 5), false);
  assert.strictEqual(byteRanges.hasRange(5, 9, 9), false);
  assert.strictEqual(byteRanges.hasRange(5, 0, 0), true);
  
  var chunks = [
    new Buffer([1,2,3]),
    new Buffer([4,5,6])
  ];

  assert.deepEqual(byteRanges.getRange(chunks, 6, 1, 4),
                   new Buffer([2,3,4,5]));
});

tests.forEach(function(testSuiteFunction) {
  console.log("Running test suite: " + testSuiteFunction.name + "...");
  testSuiteFunction();
});

console.log("Done, all tests passed!");

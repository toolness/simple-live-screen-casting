const RANGE_HEADER = /^bytes=(\d+)-(\d*)$/;

exports.parseHeader = function parseHeader(value) {
  var match = value.match(RANGE_HEADER);
  if (match)
    return {
      start: parseInt(match[1]),
      end: parseInt(match[2]) || null
    };
  return null;
};

exports.hasRange = function hasRange(length, start, end) {
  if (start >= 0 && start < length) {
    if (typeof(end) == 'number') {
      if (end >= start && end < length)
        return true;
      else
        return false;
    } else
      return true;
  } else
    return false;
};

exports.getRange = function getRange(chunks, length, start, end) {
  // TODO: Creating a temporary buffer here isn't very
  // performant, but it works for now.
  var tempBuffer = new Buffer(length);
  var pos = 0;
  chunks.forEach(function(chunk) {
    chunk.copy(tempBuffer, pos);
    pos += chunk.length;
  });
  return tempBuffer.slice(start, end+1);
};

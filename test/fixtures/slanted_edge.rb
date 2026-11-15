# A block with a sloping top standing against a wall: the sloping edges run into the wall at an angle.
# points, faces (loops of point ids, outer first; normal; sel = part of the
# selected surface) and soft edges. Units: inches.
{ :points => [
  [227.362205, 0.0, 88.59748],
  [227.362205, 0.0, 0.0],
  [227.362205, -37.795276, 0.0],
  [227.362205, -37.795276, 59.910313],
  [278.740157, 0.0, 88.59748],
  [278.740157, -37.795276, 59.910313],
  [175.984252, 0.0, 0.0],
  [278.740157, 0.0, 110.629921],
  [175.984252, 0.0, 110.629921],
  [278.740157, -37.795276, 0.0],
  [278.740157, 115.354331, 0.0],
  [278.740157, 115.354331, 110.629921],
  [175.984252, 115.354331, 110.629921],
  [175.984252, 115.354331, 0.0]
],
  :faces => [
  {:loops=>[[0, 1, 2, 3]], :normal=>[-1.0, 0.0, 0.0], :sel=>false},
  {:loops=>[[4, 0, 3, 5]], :normal=>[0.0, -0.604585629, 0.796540154], :sel=>false},
  {:loops=>[[6, 1, 0, 4, 7, 8]], :normal=>[0.0, -1.0, 0.0], :sel=>false},
  {:loops=>[[9, 10, 11, 7, 4, 5]], :normal=>[1.0, 0.0, 0.0], :sel=>false},
  {:loops=>[[9, 5, 3, 2]], :normal=>[0.0, -1.0, 0.0], :sel=>false},
  {:loops=>[[7, 11, 12, 8]], :normal=>[0.0, 0.0, 1.0], :sel=>false},
  {:loops=>[[13, 6, 8, 12]], :normal=>[-1.0, 0.0, 0.0], :sel=>false},
  {:loops=>[[10, 13, 12, 11]], :normal=>[0.0, 1.0, 0.0], :sel=>false},
  {:loops=>[[10, 9, 2, 1, 6, 13]], :normal=>[0.0, 0.0, -1.0], :sel=>false}
],
  :soft => [] }

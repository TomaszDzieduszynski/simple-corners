# A block with a sloping top against a wall, its side one face with the side of the wall (reflex corner at the top of the sloping edge).
# points, faces (loops of point ids, outer first; normal; sel = part of the
# selected surface) and soft edges. Units: inches.
{ :points => [
  [102.755906, 115.354331, 0.0],
  [102.755906, -37.795276, 0.0],
  [51.377953, -37.795276, 0.0],
  [51.377953, 0.0, 0.0],
  [0.0, 0.0, 0.0],
  [0.0, 115.354331, 0.0],
  [102.755906, 0.0, 110.629921],
  [102.755906, 115.354331, 110.629921],
  [0.0, 115.354331, 110.629921],
  [0.0, 0.0, 110.629921],
  [102.755906, 0.0, 88.59748],
  [102.755906, -37.795276, 59.910313],
  [51.377953, -37.795276, 59.910313],
  [51.377953, -0.0, 88.59748]
],
  :faces => [
  {:loops=>[[0, 1, 2, 3, 4, 5]], :normal=>[0.0, 0.0, -1.0], :sel=>false},
  {:loops=>[[6, 7, 8, 9]], :normal=>[0.0, 0.0, 1.0], :sel=>false},
  {:loops=>[[5, 4, 9, 8]], :normal=>[-1.0, 0.0, 0.0], :sel=>false},
  {:loops=>[[0, 5, 8, 7]], :normal=>[-0.0, 1.0, 0.0], :sel=>false},
  {:loops=>[[1, 0, 7, 6, 10, 11]], :normal=>[1.0, -0.0, -0.0], :sel=>false},
  {:loops=>[[1, 11, 12, 2]], :normal=>[0.0, -1.0, 0.0], :sel=>false},
  {:loops=>[[11, 10, 13, 12]], :normal=>[0.0, -0.604585629, 0.796540154], :sel=>false},
  {:loops=>[[4, 3, 13, 10, 6, 9]], :normal=>[0.0, -1.0, 0.0], :sel=>false},
  {:loops=>[[3, 2, 12, 13]], :normal=>[-1.0, 0.0, 0.0], :sel=>false}
],
  :soft => [] }

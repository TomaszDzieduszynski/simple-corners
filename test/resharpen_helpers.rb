# Round trip for the revert engine: a solid is rounded / mitred / bevelled
# by Core::Engine, the new surface is reverted by Resharpen, and the result
# is compared with the original solid.
require_relative 'mesh_helpers'
require_relative '../src/simple_corners/resharpen'

module ResharpenHelpers
  M = MeshHelpers
  V = SimpleCorners::Core::V
  R = SimpleCorners::Resharpen

  # The engine's result as a plain mesh: points, faces ({:loops, :normal,
  # :soft}) and the ids of the new faces (the rounded surface).
  def self.rounded(mesh, sel, opts, triangulate = false)
    eng = SimpleCorners::Core::Engine.fit(mesh.points, mesh.faces, sel, opts)
    polys = M.result_polys(mesh, eng)
    n_orig = mesh.faces.size
    map = {}
    pts = []
    id = lambda { |i| map[i] ||= (pts << eng.points[i]; pts.size - 1) }
    loops = []
    region = []
    polys.each_with_index do |ls, k|
      next if ls.empty? || ls[0].size < 3
      ls = ls.map { |lp| lp.map { |i| id.call(i) } }
      if k >= n_orig && triangulate && ls.size == 1 && ls[0].size > 3
        lp = ls[0]
        (1...lp.size - 1).each do |j|
          region << loops.size
          loops << [[lp[0], lp[j], lp[j + 1]]]
        end
        next
      end
      region << loops.size if k >= n_orig
      loops << ls
    end
    soft = {}
    eng.soft.each_key { |a, b| soft[[map[a], map[b]].sort] = true if map[a] && map[b] }
    edge_faces = Hash.new { |h, k| h[k] = [] }
    loops.each_with_index do |ls, fi|
      ls.each { |lp| lp.each_index { |i| edge_faces[[lp[i], lp[(i + 1) % lp.size]].sort] << fi } }
    end
    faces = loops.each_with_index.map do |ls, fi|
      partners = []
      ls.each do |lp|
        lp.each_index do |i|
          k = [lp[i], lp[(i + 1) % lp.size]].sort
          partners.concat(edge_faces[k] - [fi]) if soft[k]
        end
      end
      { :loops => ls, :normal => V.norm(V.newell(ls[0].map { |i| pts[i] })), :soft => partners.uniq }
    end
    [pts, faces, region, eng]
  end

  # Reverts region; returns the resulting polygons (loops of coordinates,
  # outward), or raises Resharpen::Error.
  def self.revert(pts, faces, region)
    res = R.solve(pts, faces, region)
    rset = {}
    region.each { |f| rset[f] = true }
    out = []
    faces.each_with_index do |f, fi|
      next if rset[fi]
      if res[fi]
        ls = res[fi].map(&:dup)
        ls[0].reverse! if V.dot(V.newell(ls[0]), f[:normal]) < 0
        ls[1..-1].each { |h| h.reverse! if V.dot(V.newell(h), f[:normal]) > 0 }
        out << ls
      else
        out << f[:loops].map { |lp| lp.map { |i| pts[i] } }
      end
    end
    out
  end

  def self.original_polys(mesh)
    mesh.faces.map { |f| f[:loops].map { |lp| lp.map { |i| mesh.points[i] } } }
  end

  def self.volume(polys)
    polys.inject(0.0) do |vol, ls|
      ls.inject(vol) do |v, lp|
        (1...lp.size - 1).inject(v) { |s, i| s + V.dot(lp[0], V.cross(lp[i], lp[i + 1])) / 6.0 }
      end
    end
  end

  def self.qkey(q, tol)
    q.map { |c| (c / tol).round }
  end

  # Problems of a polygon set: open or inconsistently oriented edges.
  def self.closed_problems(polys, tol)
    dir = Hash.new(0)
    polys.each do |ls|
      ls.each do |lp|
        ks = lp.map { |q| qkey(q, tol) }
        ks.each_index { |i| dir[[ks[i], ks[(i + 1) % ks.size]]] += 1 }
      end
    end
    probs = []
    dir.each do |(a, b), c|
      probs << 'zero edge' if a == b
      probs << "edge used #{c}x" if c != 1
      probs << 'edge without opposite' unless dir.key?([b, a])
    end
    probs.uniq
  end

  # Corner points, without points in the middle of a straight edge (an
  # extra point on an edge cannot be told from the geometry and does not
  # change the shape).
  def self.corners(polys, tol)
    nbr = Hash.new { |h, k| h[k] = {} }
    pos = {}
    polys.each do |ls|
      ls.each do |lp|
        ks = lp.map { |q| qkey(q, tol) }
        ks.each_index do |i|
          a = ks[i]
          b = ks[(i + 1) % ks.size]
          pos[a] = lp[i]
          nbr[a][b] = true
          nbr[b][a] = true
        end
      end
    end
    pos.keys.reject do |k|
      ns = nbr[k].keys
      next false unless ns.size == 2
      u = V.sub(pos[ns[0]], pos[k])
      w = V.sub(pos[ns[1]], pos[k])
      V.len(V.cross(u, w)) <= tol * (V.len(u) + V.len(w)) && V.dot(u, w) < 0
    end.sort
  end

  # Compares the reverted result with the original solid. Returns a list
  # of differences (empty: identical).
  def self.compare(mesh, polys)
    ext = (0..2).map { |i| mesh.points.map { |p| p[i] }.max - mesh.points.map { |p| p[i] }.min }.max
    tol = 1e-6 * (1 + ext)
    orig = original_polys(mesh)
    diffs = closed_problems(polys, tol)
    v0 = volume(orig)
    v1 = volume(polys)
    diffs << "volume #{v1} vs #{v0}" if (v1 - v0).abs > 1e-6 * (1 + v0.abs)
    diffs << "faces #{polys.size} vs #{orig.size}" if polys.size != orig.size
    diffs << 'corners differ' if corners(polys, tol) != corners(orig, tol)
    diffs
  end
end

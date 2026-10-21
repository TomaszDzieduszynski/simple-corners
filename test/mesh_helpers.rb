# Test helpers: build simple solids as abstract meshes, run the engine and
# check the result.
require_relative '../src/simple_corners/core'

module MeshHelpers
  V = SimpleCorners::Core::V

  Mesh = Struct.new(:points, :faces)

  def self.face(loops, points)
    { :loops => loops, :normal => V.norm(V.newell(loops[0].map { |i| points[i] })) }
  end

  # Extrudes a CCW 2D polygon (with optional CCW holes) along +z.
  def self.prism(poly, h, holes = [], z0 = 0.0)
    pts = []
    add = lambda { |x, y, z| pts << [x.to_f, y.to_f, z.to_f]; pts.size - 1 }
    rings = [poly] + holes
    bot = rings.map { |r| r.map { |x, y| add.call(x, y, z0) } }
    top = rings.map { |r| r.map { |x, y| add.call(x, y, z0 + h) } }
    faces = []
    # top: outer CCW, holes CW
    faces << face([top[0]] + top[1..-1].map(&:reverse), pts)
    # bottom: outer reversed
    faces << face([bot[0].reverse] + bot[1..-1], pts)
    rings.each_with_index do |r, ri|
      n = r.size
      n.times do |i|
        j = (i + 1) % n
        a0 = bot[ri][i]
        b0 = bot[ri][j]
        a1 = top[ri][i]
        b1 = top[ri][j]
        faces << face(ri == 0 ? [[a0, b0, b1, a1]] : [[b0, a0, a1, b1]], pts)
      end
    end
    Mesh.new(pts, faces)
  end

  def self.box(sx = 10, sy = 10, sz = 10)
    prism([[0, 0], [sx, 0], [sx, sy], [0, sy]], sz)
  end

  def self.lshape
    prism([[0, 0], [20, 0], [20, 8], [8, 8], [8, 20], [0, 20]], 10)
  end

  def self.cylinder(n = 24, r = 10, h = 10)
    poly = (0...n).map { |i| a = 2 * Math::PI * i / n; [r * Math.cos(a), r * Math.sin(a)] }
    prism(poly, h)
  end

  def self.plate_with_hole
    prism([[0, 0], [30, 0], [30, 30], [0, 30]], 6, [[[10, 10], [20, 10], [20, 20], [10, 20]]])
  end

  def self.pyramid(s = 10, h = 8)
    pts = [[0, 0, 0], [s, 0, 0], [s, s, 0], [0, s, 0], [s / 2.0, s / 2.0, h]].map { |p| p.map(&:to_f) }
    faces = [face([[3, 2, 1, 0]], pts)]
    4.times { |i| faces << face([[i, (i + 1) % 4, 4]], pts) }
    Mesh.new(pts, faces)
  end

  # A block with a smaller block attached to its top (as in a bug report):
  # the top of the lower block is a frame face with a hole. r1, r2: CCW
  # rectangles (r2 inside r1), h1, h2: heights.
  def self.stepped(r1 = [[0, 0], [10, 0], [10, 8], [0, 8]], r2 = [[2, 1], [8, 1], [8, 7], [2, 7]], h1 = 20, h2 = 12)
    pts = []
    ring = lambda { |r, z| r.map { |x, y| pts << [x.to_f, y.to_f, z.to_f]; pts.size - 1 } }
    a0 = ring.call(r1, 0)
    a1 = ring.call(r1, h1)
    b0 = ring.call(r2, h1)
    b1 = ring.call(r2, h1 + h2)
    faces = [face([a0.reverse], pts), face([a1, b0.reverse], pts), face([b1], pts)]
    [[a0, a1], [b0, b1]].each do |lo, hi|
      n = lo.size
      n.times { |i| faces << face([[lo[i], lo[(i + 1) % n], hi[(i + 1) % n], hi[i]]], pts) }
    end
    Mesh.new(pts, faces)
  end

  # The bug-report model: a block (x 0..10, y 0..8, z 0..20) with a smaller
  # block on its end (x 3..10, y 0..6, z 20..32), flush with its back and
  # bottom, so the end face is an L-shaped frame. With window: a tunnel
  # through the smaller block (y 2..4, z 23..29).
  def self.stepped_flush(window = true)
    pts = []
    id = {}
    pt = lambda { |x, y, z| id[[x, y, z]] ||= (pts << [x.to_f, y.to_f, z.to_f]; pts.size - 1) }
    f = lambda do |nrm, outer, holes = []|
      lp = outer.map { |c| pt.call(*c) }
      lp.reverse! if V.dot(V.newell(lp.map { |i| pts[i] }), nrm) < 0
      hs = holes.map do |h|
        hl = h.map { |c| pt.call(*c) }
        hl.reverse! if V.dot(V.newell(hl.map { |i| pts[i] }), nrm) > 0
        hl
      end
      { :loops => [lp] + hs, :normal => V.norm(nrm) }
    end
    win = window ? [[2, 23], [4, 23], [4, 29], [2, 29]] : nil
    faces = []
    faces << f.call([0, 0, -1], [[0, 0, 0], [10, 0, 0], [10, 8, 0], [0, 8, 0]])
    faces << f.call([0, 0, 1], [[0, 0, 20], [3, 0, 20], [3, 6, 20], [10, 6, 20], [10, 8, 20], [0, 8, 20]])
    faces << f.call([0, 0, 1], [[3, 0, 32], [10, 0, 32], [10, 6, 32], [3, 6, 32]])
    faces << f.call([0, -1, 0], [[0, 0, 0], [10, 0, 0], [10, 0, 32], [3, 0, 32], [3, 0, 20], [0, 0, 20]])
    faces << f.call([0, 1, 0], [[0, 8, 0], [10, 8, 0], [10, 8, 20], [0, 8, 20]])
    faces << f.call([0, 1, 0], [[3, 6, 20], [10, 6, 20], [10, 6, 32], [3, 6, 32]])
    faces << f.call([-1, 0, 0], [[0, 0, 0], [0, 8, 0], [0, 8, 20], [0, 0, 20]])
    back = [[10, 0, 0], [10, 8, 0], [10, 8, 20], [10, 6, 20], [10, 6, 32], [10, 0, 32]]
    front = [[3, 0, 20], [3, 6, 20], [3, 6, 32], [3, 0, 32]]
    if win
      faces << f.call([1, 0, 0], back, [win.map { |y, z| [10, y, z] }])
      faces << f.call([-1, 0, 0], front, [win.map { |y, z| [3, y, z] }])
      # tunnel walls, facing into the tunnel
      faces << f.call([0, 1, 0], [[3, 2, 23], [10, 2, 23], [10, 2, 29], [3, 2, 29]])
      faces << f.call([0, -1, 0], [[3, 4, 23], [10, 4, 23], [10, 4, 29], [3, 4, 29]])
      faces << f.call([0, 0, 1], [[3, 2, 23], [10, 2, 23], [10, 4, 23], [3, 4, 23]])
      faces << f.call([0, 0, -1], [[3, 2, 29], [10, 2, 29], [10, 4, 29], [3, 4, 29]])
    else
      faces << f.call([1, 0, 0], back)
      faces << f.call([-1, 0, 0], front)
    end
    Mesh.new(pts, faces)
  end

  # Leaning, tapered n-sided prism (as in a bug report): bottom radius r0,
  # top radius r1, top shifted by dx.
  def self.frustum(n = 10, r0 = 10, r1 = 7, h = 20, dx = 6)
    pts = []
    n.times { |i| a = 2 * Math::PI * i / n; pts << [r0 * Math.cos(a), r0 * Math.sin(a), 0.0] }
    n.times { |i| a = 2 * Math::PI * i / n; pts << [r1 * Math.cos(a) + dx, r1 * Math.sin(a), h.to_f] }
    faces = [face([(0...n).to_a.reverse], pts), face([(n...2 * n).to_a], pts)]
    n.times { |i| j = (i + 1) % n; faces << face([[i, j, n + j, n + i]], pts) }
    Mesh.new(pts, faces)
  end

  # Box whose top-front edge is split in two collinear edges.
  def self.split_box
    m = box
    # top-front edge goes from vertex 4 (0,0,10) to 5 (10,0,10)
    m.points << [5.0, 0.0, 10.0]
    s = m.points.size - 1
    m.faces.each do |f|
      f[:loops] = f[:loops].map do |lp|
        out = []
        lp.each_with_index do |v, i|
          w = lp[(i + 1) % lp.size]
          out << v
          out << s if [v, w].sort == [4, 5]
        end
        out
      end
    end
    m
  end

  def self.edges(mesh)
    h = {}
    mesh.faces.each do |f|
      f[:loops].each do |lp|
        lp.each_with_index { |v, i| w = lp[(i + 1) % lp.size]; h[[v, w].sort] = true }
      end
    end
    h.keys
  end

  def self.edges_where(mesh)
    edges(mesh).select { |a, b| yield mesh.points[a], mesh.points[b] }
  end

  def self.run(mesh, sel, opts)
    e = SimpleCorners::Core::Engine.new(mesh.points, mesh.faces, sel, opts)
    e.run
    e
  end

  # Final list of polygons (array of point-id loops arrays).
  def self.result_polys(mesh, eng)
    polys = []
    mesh.faces.each_with_index do |f, fi|
      polys << (eng.face_loops[fi] || f[:loops])
    end
    eng.new_polys.each { |p| polys << [p[:ids]] }
    polys
  end

  # Returns a list of problems (empty when the mesh is closed and
  # consistently oriented).
  def self.check_closed(mesh, eng)
    probs = []
    dir = Hash.new(0)
    result_polys(mesh, eng).each do |loops|
      loops.each do |lp|
        probs << "short loop #{lp.inspect}" if lp.size < 3
        lp.each_with_index do |v, i|
          w = lp[(i + 1) % lp.size]
          probs << "zero edge #{v}" if v == w
          dir[[v, w]] += 1
        end
      end
    end
    dir.each do |(a, b), c|
      probs << "directed edge #{a}-#{b} used #{c} times" if c != 1
      probs << "edge #{a}-#{b} has no opposite" unless dir.key?([b, a])
    end
    probs.uniq
  end

  # Polygons deviating from their plane by more than tol (relative to the
  # model size; SketchUp's own tolerance is 0.001 inch).
  def self.nonplanar(mesh, eng, rel_tol = 1e-6)
    bad = []
    pts = eng.points
    ext = (0..2).map { |i| mesh.points.map { |p| p[i] }.max - mesh.points.map { |p| p[i] }.min }.max
    tol = rel_tol * ext
    result_polys(mesh, eng).each do |loops|
      all = loops.flatten.map { |i| pts[i] }
      n = V.norm(V.newell(loops[0].map { |i| pts[i] }))
      c = all[0]
      dev = all.map { |p| V.dot(V.sub(p, c), n).abs }.max
      bad << dev if dev > tol
    end
    bad
  end

  def self.volume(mesh, eng)
    pts = eng.points
    vol = 0.0
    result_polys(mesh, eng).each do |loops|
      loops.each do |lp|
        p0 = pts[lp[0]]
        (1...lp.size - 1).each do |i|
          vol += V.dot(p0, V.cross(pts[lp[i]], pts[lp[i + 1]])) / 6.0
        end
      end
    end
    vol
  end

  # Problems of faces with holes in the result: each loop keeps its
  # orientation and every hole lies inside the outer loop.
  def self.hole_problems(mesh, eng)
    probs = []
    area = lambda { |p| (0...p.size).inject(0.0) { |a, i| q = p[(i + 1) % p.size]; a + p[i][0] * q[1] - q[0] * p[i][1] } }
    inside = lambda do |pt, poly|
      x, y = pt
      r = false
      poly.size.times do |i|
        a = poly[i]
        b = poly[(i + 1) % poly.size]
        next unless (a[1] > y) != (b[1] > y)
        r = !r if x < a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
      end
      r
    end
    mesh.faces.each_with_index do |f, fi|
      loops = eng.face_loops[fi] || f[:loops]
      next if loops.size < 2
      ax = f[:normal].map(&:abs)
      keep = [0, 1, 2] - [ax.index(ax.max)]
      ps = loops.map { |lp| lp.map { |i| eng.points[i].values_at(*keep) } }
      o0 = f[:loops][0].map { |i| mesh.points[i].values_at(*keep) }
      ok = area.call(ps[0]) * area.call(o0) > 0 &&
           ps[1..-1].all? { |h| area.call(h) * area.call(ps[0]) < 0 && h.all? { |q| inside.call(q, ps[0]) } }
      probs << "face #{fi}: hole outside or flipped" unless ok
    end
    probs
  end

  def self.write_obj(path, mesh, eng)
    pts = eng.points
    File.open(path, 'w') do |f|
      pts.each { |p| f.puts "v #{p[0]} #{p[1]} #{p[2]}" }
      result_polys(mesh, eng).each do |loops|
        # holes are not representable in OBJ: write outer loop only, holes
        # are drawn by the renderer from a separate list.
        f.puts 'f ' + loops[0].map { |i| i + 1 }.join(' ')
        loops[1..-1].each { |lp| f.puts '#hole ' + lp.map { |i| i + 1 }.join(' ') }
      end
      eng.soft.each_key { |a, b| f.puts "#soft #{a + 1} #{b + 1}" }
    end
  end
end

require 'tmpdir'
require_relative '../mesh_helpers'
require 'benchmark'
M = MeshHelpers; V = M::V
# Geodesic sphere: icosahedron with each face split into freq^2 triangles.
def icosphere(freq, r)
  t = (1 + Math.sqrt(5)) / 2
  base = [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]].map { |p| V.norm(p) }
  tris = [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
          [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
  pts = []; idx = {}
  key = lambda { |p| p.map { |x| (x * 1e6).round } }
  add = lambda { |p| p = V.mul(V.norm(p), r); k = key.call(p); idx[k] ||= (pts << p; pts.size - 1) }
  faces = []
  tris.each do |a, b, c|
    pa, pb, pc = base[a], base[b], base[c]
    g = lambda { |i, j| V.add(V.add(V.mul(pa, (freq - i - j).to_f / freq), V.mul(pb, i.to_f / freq)), V.mul(pc, j.to_f / freq)) }
    (0...freq).each do |i|
      (0...(freq - i)).each do |j|
        faces << [add.call(g.call(i, j)), add.call(g.call(i + 1, j)), add.call(g.call(i, j + 1))]
        faces << [add.call(g.call(i + 1, j)), add.call(g.call(i + 1, j + 1)), add.call(g.call(i, j + 1))] if i + j < freq - 1
      end
    end
  end
  fs = faces.map do |f|
    n = V.newell(f.map { |i| pts[i] })
    f = f.reverse if V.dot(n, pts[f[0]]) < 0
    M.face([f], pts)
  end
  M::Mesh.new(pts, fs)
end
mesh = icosphere((ARGV[2] || 4).to_i, 20.0)
f0 = mesh.faces.max_by { |f| f[:loops][0].map { |i| mesh.points[i][2] }.min }  # a top face
lp = f0[:loops][0]
nf = (ARGV[3] || 1).to_i
sel_faces = [f0]
# grow selection to nf faces around f0
while sel_faces.size < nf
  cand = mesh.faces.find { |f| !sel_faces.include?(f) && sel_faces.any? { |s| (s[:loops][0] & f[:loops][0]).size == 2 } }
  sel_faces << cand
end
sel = sel_faces.flat_map { |f| l = f[:loops][0]; (0...l.size).map { |i| [l[i], l[(i + 1) % l.size]].sort } }.uniq
mode = (ARGV[0] || 'round').to_sym
off = (ARGV[1] || 1.0).to_f
eng = nil
t = Benchmark.realtime { eng = SimpleCorners::Core::Engine.fit(mesh.points, mesh.faces, sel, :mode => mode, :offset => off, :segments => 6) }
puts "#{mode} off=#{off} faces=#{mesh.faces.size} sel=#{sel.size} time=#{(t * 1000).round}ms closed=#{M.check_closed(mesh, eng).empty?} reduced=#{eng.reduced.size} polys=#{eng.new_polys.size}"
M.write_obj(ARGV[4] || File.join(Dir.tmpdir, 'd.obj'), mesh, eng)
c = V.avg(lp.map { |i| mesh.points[i] })
puts "zoom: #{c.map { |x| x.round(2) }.join(',')}"

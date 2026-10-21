require 'tmpdir'
require_relative '../mesh_helpers'
M = MeshHelpers; V = M::V
# Step 1: L-shape, round the concave vertical edge (like the user's model).
l = M.lshape
concave = M.edges_where(l) { |a, b| a[0] == 8 && b[0] == 8 && a[1] == 8 && b[1] == 8 }
e1 = M.run(l, concave, :mode => :round, :offset => 3.0, :segments => (ARGV[1] || 6).to_i)
# Rebuild a clean mesh from the result.
polys = M.result_polys(l, e1)
used = {}; polys.each { |lps| lps.flatten.each { |i| used[i] = true } }
map = {}; pts = []
used.keys.sort.each { |i| map[i] = pts.size; pts << e1.points[i] }
faces = polys.map { |lps| M.face(lps.map { |lp| lp.map { |i| map[i] } }, pts) }
m2 = M::Mesh.new(pts, faces)
# Step 2: select the wall face y=8 (x from 11 to 20) and bevel its edges.
wall = faces.find { |f| f[:normal][1] > 0.99 && f[:loops][0].all? { |i| (pts[i][1] - 8).abs < 1e-9 } && f[:loops][0].map { |i| pts[i][0] }.max > 19 }
lp = wall[:loops][0]
sel = (0...lp.size).map { |i| [lp[i], lp[(i + 1) % lp.size]] }
puts "wall loop: #{lp.map { |i| pts[i].map { |x| x.round(2) } }.inspect}"
mode = (ARGV[0] || 'bevel').to_sym
e2 = M.run(m2, sel, :mode => mode, :offset => (ARGV[2] || 1.0).to_f, :segments => 4)
puts "closed: #{M.check_closed(m2, e2).empty?}"
# Horn check: every new point must stay inside the original L outline
# (x,y in the L, z in 0..10) - rounding/bevel only removes material here.
bad = e2.points.each_index.select do |i|
  next false if i < pts.size
  p = e2.points[i]
  out = p[2] < -1e-6 || p[2] > 10 + 1e-6 || p[0] < -1e-6 || p[1] < -1e-6 || p[0] > 20 + 1e-6 || p[1] > 20 + 1e-6
  inside_notch = p[0] > 8 + 3.0 + 1e-6 && p[1] > 8 + 1e-6 # notch region beyond the fillet
  out || inside_notch
end
puts "points outside the solid: #{bad.size} #{bad.first(4).map { |i| e2.points[i].map { |x| x.round(3) } }.inspect}"
M.write_obj(ARGV[3] || File.join(Dir.tmpdir, 'r.obj'), m2, e2)
